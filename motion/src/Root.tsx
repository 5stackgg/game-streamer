import { Composition } from "remotion";
import { Outro, outroSchema, DEFAULT_OUTRO_PROPS } from "./Outro";
import {
  PlayerChip,
  playerChipSchema,
  DEFAULT_CHIP_PROPS,
  CHIP_DURATION_S,
} from "./PlayerChip";

// `calculateMetadata` lets the same composition serve 1080p and 720p
// (the api emits clips at either) — the CLI / SDK passes
// `props.width` / `props.height` / `props.fps` and the comp resizes
// to match. Keeps a single source of truth for the design.

export const Root: React.FC = () => {
  return (
    <>
      <Composition
        id="Outro"
        component={Outro}
        defaultProps={DEFAULT_OUTRO_PROPS}
        schema={outroSchema}
        width={DEFAULT_OUTRO_PROPS.width}
        height={DEFAULT_OUTRO_PROPS.height}
        fps={DEFAULT_OUTRO_PROPS.fps}
        durationInFrames={Math.round(
          DEFAULT_OUTRO_PROPS.durationS * DEFAULT_OUTRO_PROPS.fps,
        )}
        calculateMetadata={({ props }) => ({
          width: props.width,
          height: props.height,
          fps: props.fps,
          durationInFrames: Math.round(props.durationS * props.fps),
        })}
      />
      <Composition
        id="PlayerChip"
        component={PlayerChip}
        defaultProps={DEFAULT_CHIP_PROPS}
        schema={playerChipSchema}
        width={DEFAULT_CHIP_PROPS.width}
        height={DEFAULT_CHIP_PROPS.height}
        fps={DEFAULT_CHIP_PROPS.fps}
        durationInFrames={Math.round(CHIP_DURATION_S * DEFAULT_CHIP_PROPS.fps)}
        calculateMetadata={({ props }) => ({
          width: props.width,
          height: props.height,
          fps: props.fps,
          durationInFrames: Math.round(CHIP_DURATION_S * props.fps),
        })}
      />
    </>
  );
};
