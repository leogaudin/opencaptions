/**
 * Playback-capability detection for the preview.
 *
 * A browser can be unable to PLAY a video the user can still download and open
 * elsewhere. WebM on Apple platforms is the sharp case. So a negative verdict
 * must offer the download rather than present the video as broken, and an
 * absent or throwing API must never block playback.
 */

/** A container + codec combination to test for decode support. */
export interface CodecQuery {
  /** Video container MIME type, e.g. "video/webm" or "video/mp4". */
  container: string;
  /** Video codec string, RFC 6381 form preferred, e.g. "vp09.00.10.08". */
  videoCodec: string;
  /**
   * Audio codec string, e.g. "opus", "vorbis", "mp4a.40.2". Optional, but
   * strongly recommended: the audio track is the WebM-on-Safari failure mode.
   */
  audioCodec?: string;
}

/** Verdict for a capability probe. "unknown" means no API could answer. */
export type PlaybackSupport = "supported" | "unsupported" | "unknown";

/** Build a `video/...; codecs="..."` content-type string for a query. */
function videoContentType(query: CodecQuery): string {
  const codecs = query.audioCodec ? `${query.videoCodec}, ${query.audioCodec}` : query.videoCodec;
  return `${query.container}; codecs="${codecs}"`;
}

/** Probe container+codec support. Only a positive "no" yields "unsupported". */
export async function probePlaybackSupport(query: CodecQuery): Promise<PlaybackSupport> {
  const caps = typeof navigator !== "undefined" ? navigator.mediaCapabilities : undefined;
  if (caps && typeof caps.decodingInfo === "function") {
    try {
      const config: MediaDecodingConfiguration = {
        type: "file",
        video: {
          contentType: `${query.container}; codecs="${query.videoCodec}"`,
          width: 1280,
          height: 720,
          bitrate: 2_000_000,
          framerate: 30,
        },
      };
      if (query.audioCodec) {
        // The audio track lives in the same container; query it as audio/<x>.
        const audioContainer = query.container.replace(/^video\//, "audio/");
        config.audio = { contentType: `${audioContainer}; codecs="${query.audioCodec}"` };
      }
      const info = await caps.decodingInfo(config);
      return info.supported ? "supported" : "unsupported";
    } catch {
      // decodingInfo rejects on a malformed configuration, fall through to the
      // canPlayType fallback rather than treating that as "unsupported".
    }
  }

  // Fallback: canPlayType. Unreliable (see file header), used only when Media
  // Capabilities is absent. "" is a definite no; "maybe"/"probably" a weak yes.
  if (typeof document !== "undefined") {
    const verdict = document.createElement("video").canPlayType(videoContentType(query));
    return verdict === "" ? "unsupported" : "supported";
  }
  return "unknown";
}

/** Lower-cased file extension (without the dot) of a storage key or filename. */
function extensionOf(keyOrName: string | null | undefined): string | null {
  if (!keyOrName?.includes(".")) return null;
  return keyOrName.slice(keyOrName.lastIndexOf(".") + 1).toLowerCase();
}

/**
 * Pre-check query for a storage key, or null to defer to the element's error
 * event. Only WebM is pre-checked: there a false verdict on VP9+Opus reliably
 * means the engine cannot play WebM at all.
 */
export function previewQueryForSource(
  storageKeyOrName: string | null | undefined,
): CodecQuery | null {
  if (extensionOf(storageKeyOrName) === "webm") {
    return { container: "video/webm", videoCodec: "vp09.00.10.08", audioCodec: "opus" };
  }
  return null;
}
