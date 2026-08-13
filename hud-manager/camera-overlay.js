// Injected into the JTs Hud Manager overlay window by auto-overlay.patch.
//
// Kept as a self-contained IIFE appended to document.body rather than a change
// to the HUD's own markup: the HUD is upstream and its DOM is not ours to
// restructure, so this only ever adds one element of its own.
//
// The spectated player comes from the spec-server, which already tracks it from
// GSI, so the camera always follows what viewers are actually watching. The
// SDP exchange is proxied by that same server because it holds the pod's match
// credentials and this page must not.
(() => {
  const SPEC_BASE = window.__FIVESTACK_SPEC_BASE__ || "http://127.0.0.1:1350";
  const POLL_MS = 2000;
  // A player with no camera fails every attempt; back off rather than
  // renegotiating a doomed peer connection every couple of seconds.
  const RETRY_BACKOFF_MS = 15000;

  const video = document.createElement("video");
  video.autoplay = true;
  video.muted = true;
  video.playsInline = true;
  video.id = "fivestack-camera";
  Object.assign(video.style, {
    position: "fixed",
    right: "24px",
    bottom: "96px",
    width: "260px",
    borderRadius: "6px",
    border: "2px solid rgba(0,0,0,0.55)",
    boxShadow: "0 8px 28px rgba(0,0,0,0.55)",
    background: "#000",
    zIndex: "2147483000",
    opacity: "0",
    transition: "opacity 220ms ease",
    pointerEvents: "none",
    objectFit: "cover",
  });
  document.body.appendChild(video);

  let currentSteamId = null;
  let pc = null;
  const failedUntil = new Map();

  const show = (visible) => {
    video.style.opacity = visible ? "1" : "0";
  };

  function teardown() {
    show(false);

    if (pc) {
      pc.close();
      pc = null;
    }

    video.srcObject = null;
    currentSteamId = null;
  }

  async function connect(steamId) {
    const peer = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });
    pc = peer;
    currentSteamId = steamId;

    peer.addTransceiver("video", { direction: "recvonly" });
    peer.ontrack = (event) => {
      video.srcObject = event.streams[0];
      void video.play().catch(() => {});
      // Only reveal once a track actually arrives, so a negotiated-but-silent
      // path never shows as a black box over the broadcast.
      show(true);
    };

    peer.addEventListener("connectionstatechange", () => {
      if (["failed", "disconnected", "closed"].includes(peer.connectionState)) {
        if (pc === peer) {
          teardown();
        }
      }
    });

    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);

    await new Promise((resolve) => {
      if (peer.iceGatheringState === "complete") {
        resolve();
        return;
      }
      peer.addEventListener("icegatheringstatechange", () => {
        if (peer.iceGatheringState === "complete") resolve();
      });
      setTimeout(resolve, 1500);
    });

    const response = await fetch(`${SPEC_BASE}/camera/${steamId}/whep`, {
      method: "POST",
      headers: { "Content-Type": "application/sdp" },
      body: peer.localDescription?.sdp ?? "",
    });

    if (!response.ok) {
      throw new Error(String(response.status));
    }

    await peer.setRemoteDescription({
      type: "answer",
      sdp: await response.text(),
    });
  }

  async function tick() {
    try {
      const response = await fetch(`${SPEC_BASE}/camera/state`);
      const state = response.ok ? await response.json() : null;
      const steamId = state?.enabled ? state.steam_id : null;

      if (!steamId) {
        if (currentSteamId) teardown();
        return;
      }

      if (steamId === currentSteamId) {
        return;
      }

      const backoff = failedUntil.get(steamId) ?? 0;
      if (Date.now() < backoff) {
        return;
      }

      teardown();

      try {
        await connect(steamId);
        failedUntil.delete(steamId);
      } catch {
        failedUntil.set(steamId, Date.now() + RETRY_BACKOFF_MS);
        teardown();
      }
    } catch {
      // spec-server not up yet, or mid-restart. Try again next tick.
    }
  }

  setInterval(tick, POLL_MS);
  void tick();
})();
