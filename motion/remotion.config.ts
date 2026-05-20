import { Config } from "@remotion/cli/config";

// Concurrency 1 keeps memory predictable in the render pod — these
// compositions are short (4s outro, ~3.5s chip) so parallelism wouldn't
// buy much anyway.
Config.setConcurrency(1);
Config.setVideoImageFormat("jpeg");
Config.setOverwriteOutput(true);
