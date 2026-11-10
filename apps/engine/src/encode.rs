//! How FFmpeg makes the file: the encoder for each codec, how colour is treated, and the command
//! that lays the caption band over the source. Pure, so the render server and the npm package
//! (over WebAssembly) run the same command: each starts FFmpeg itself and pipes the band in.

use serde::{Deserialize, Serialize};

use crate::Scene;

/// Encoder arguments and the pixel format the composite is converted to.
#[derive(Debug)]
pub struct Encoding {
    pub args: Vec<String>,
    pub pix_fmt: &'static str,
    /// The 10-bit format to keep an HDR source HDR in, for codecs that can carry
    /// it. H.264 cannot in any widely playable profile, so it is tone-mapped.
    pub hdr_pix_fmt: Option<&'static str>,
    pub content_type: &'static str,
}

pub fn encoding(
    codec: &str,
    crf: Option<u32>,
    pro_res_profile: Option<&str>,
) -> Result<Encoding, String> {
    let crf = || {
        crf.map(|c| c.to_string())
            .ok_or(format!("crf is required for {codec}"))
    };
    let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    Ok(match codec {
        "h264" => Encoding {
            args: [
                args(&["-c:v", "libx264", "-preset", "medium", "-crf"]),
                vec![crf()?],
            ]
            .concat(),
            pix_fmt: "yuv420p",
            hdr_pix_fmt: None,
            content_type: "video/mp4",
        },
        "h265" => Encoding {
            args: [
                args(&[
                    "-c:v", "libx265", "-preset", "medium", "-tag:v", "hvc1", "-crf",
                ]),
                vec![crf()?],
            ]
            .concat(),
            pix_fmt: "yuv420p",
            hdr_pix_fmt: Some("yuv420p10le"),
            content_type: "video/mp4",
        },
        "vp9" => Encoding {
            args: [
                args(&["-c:v", "libvpx-vp9", "-row-mt", "1", "-b:v", "0", "-crf"]),
                vec![crf()?],
            ]
            .concat(),
            pix_fmt: "yuv420p",
            hdr_pix_fmt: Some("yuv420p10le"),
            content_type: "video/webm",
        },
        "prores" => {
            let (profile, pix_fmt) = match pro_res_profile.unwrap_or("hq") {
                "proxy" => ("0", "yuv422p10le"),
                "light" => ("1", "yuv422p10le"),
                "standard" => ("2", "yuv422p10le"),
                "hq" => ("3", "yuv422p10le"),
                "4444" => ("4", "yuv444p10le"),
                "4444-xq" => ("5", "yuv444p10le"),
                other => return Err(format!("unknown ProRes profile {other:?}")),
            };
            Encoding {
                args: args(&["-c:v", "prores_ks", "-profile:v", profile]),
                pix_fmt,
                hdr_pix_fmt: Some(pix_fmt),
                content_type: "video/quicktime",
            }
        }
        other => return Err(format!("unsupported codec {other:?}")),
    })
}

pub fn audio_args(codec: &str) -> &'static [&'static str] {
    match codec {
        "vp9" => &["-c:a", "libopus", "-b:a", "160k"],
        "prores" => &["-c:a", "pcm_s16le"],
        _ => &["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"],
    }
}

/// What ffprobe is given, before the source, to print its transfer function (empty when unknown).
pub const PROBE_ARGS: [&str; 8] = [
    "-v",
    "error",
    "-select_streams",
    "v:0",
    "-show_entries",
    "stream=color_transfer",
    "-of",
    "default=nw=1:nk=1",
];

/// How a render treats colour, decided by the source and the output codec.
pub enum Colour {
    /// SDR in, SDR out: composite in RGB, encode BT.709.
    Sdr,
    /// HDR in, SDR-only codec out: tone-map to BT.709 first, then as SDR.
    ToneMapped,
    /// HDR in, HDR-capable codec out: composite in the source's own BT.2020
    /// space at 10 bits, and keep its transfer function.
    Hdr {
        transfer: String,
        pix_fmt: &'static str,
    },
}

/// Diffuse white in nits: where phones record white (BT.2408), and so where the
/// tone-map pins SDR white.
pub const SDR_WHITE_NITS: u32 = 203;

/// The scale that puts caption white on that same reference white, measured: it
/// lands within 1% of BT.2408 graphics white in both PQ and HLG.
pub const CAPTION_NPL: u32 = 160;

impl Colour {
    pub fn of(transfer: &str, hdr_pix_fmt: Option<&'static str>) -> Self {
        let hdr = matches!(transfer, "smpte2084" | "arib-std-b67");
        match (hdr, hdr_pix_fmt) {
            (false, _) => Self::Sdr,
            (true, None) => Self::ToneMapped,
            (true, Some(pix_fmt)) => Self::Hdr {
                transfer: transfer.into(),
                pix_fmt,
            },
        }
    }

    /// The filter graph. The captions come in as a picture of `band` (x, y, width, height) only,
    /// and are laid over the video there.
    pub fn filter(
        &self,
        (w, h, fps): (u32, u32, u32),
        band: (u32, u32),
        sdr_pix_fmt: &str,
        green_screen: bool,
    ) -> String {
        let at = format!("x={}:y={}", band.0, band.1);
        let base = if green_screen {
            format!("color=c=0x00FF00:s={w}x{h}:r={fps},setsar=1")
        } else {
            format!("[0:v]setpts=PTS-STARTPTS,fps={fps},scale={w}:{h}:flags=lanczos,setsar=1")
        };
        let cap = "[1:v]setpts=PTS-STARTPTS";
        // RGB compositing keeps the overlay at full chroma; the conversion is
        // explicit BT.709 rather than FFmpeg's BT.601 default.
        let sdr = |pre: &str| {
            format!(
                "{base}{pre},format=gbrp[base];{cap}[cap];\
                 [base][cap]overlay={at}:format=gbrp:eof_action=pass,\
                 scale=out_color_matrix=bt709:out_range=tv,format={sdr_pix_fmt}[v]"
            )
        };
        match self {
            Self::Sdr => sdr(""),
            // Mobius keeps the picture's own brightness and compresses only the
            // highlights above SDR white; Hable darkened mid-tones by a third.
            Self::ToneMapped => sdr(&format!(
                ",zscale=t=linear:npl={SDR_WHITE_NITS},format=gbrpf32le,zscale=p=bt709,\
                 tonemap=mobius:desat=0,zscale=t=bt709:m=bt709:r=tv"
            )),
            // This FFmpeg's overlay has no 10-bit 4:4:4 mode, so it composites at
            // 4:2:2: luma, where text edges live, stays at full resolution.
            Self::Hdr { transfer, pix_fmt } => format!(
                "{base},format=yuv422p10le[base];\
                 {cap},zscale=tin=iec61966-2-1:pin=bt709:min=gbr:rin=pc:\
                 t={transfer}:p=bt2020:m=bt2020nc:r=tv:npl={CAPTION_NPL},format=yuva422p10le[cap];\
                 [base][cap]overlay={at}:format=yuv422p10:eof_action=pass,format={pix_fmt}[v]"
            ),
        }
    }

    pub fn tags(&self) -> [&str; 6] {
        let (space, primaries, transfer) = match self {
            Self::Sdr | Self::ToneMapped => ("bt709", "bt709", "bt709"),
            Self::Hdr { transfer, .. } => ("bt2020nc", "bt2020", transfer.as_str()),
        };
        [
            "-colorspace",
            space,
            "-color_primaries",
            primaries,
            "-color_trc",
            transfer,
        ]
    }
}

/// What a file is made from: the source, where it goes, and how it is encoded.
#[derive(Deserialize)]
pub struct Output {
    /// The source as FFmpeg opens it (a path or a URL), and the file to write.
    pub source: String,
    pub output: String,
    /// Options FFmpeg takes before opening the source, such as the protocols it may use.
    #[serde(default)]
    pub source_options: Vec<String>,
    /// The source's transfer function as ffprobe names it (`PROBE_ARGS`), empty when unknown.
    #[serde(default)]
    pub source_transfer: String,
    /// The length to make, in seconds: the transcript's.
    pub duration: f32,
    pub fps: u32,
    pub codec: String,
    pub crf: Option<u32>,
    pub pro_res_profile: Option<String>,
    /// Captions over solid chroma green instead of the video, with no sound.
    #[serde(default)]
    pub green_screen: bool,
}

/// The FFmpeg command for a scene, and what to pipe into it: `frames` pictures of `band`
/// (x, y, width, height) cut from each frame the scene draws, as raw RGBA.
#[derive(Debug, Serialize)]
pub struct Plan {
    pub args: Vec<String>,
    pub frames: u32,
    pub band: (u32, u32, u32, u32),
    pub content_type: &'static str,
}

pub fn plan(scene: &Scene, out: &Output) -> Result<Plan, String> {
    if !(1..=120).contains(&out.fps) {
        return Err("fps must be between 1 and 120".into());
    }
    let enc = encoding(&out.codec, out.crf, out.pro_res_profile.as_deref())?;
    let duration = out.duration.max(1.0 / out.fps as f32);
    let (w, h) = (scene.width(), scene.height());
    // Only the box the captions can ever be in is sent for each frame, and laid over the
    // video where it belongs: at 1080x1920 that is a few hundred rows of a frame, not all of it.
    let (bx, by, bw, bh) = scene.overlay_bounds();
    // Composited in RGB so the overlay blends at full chroma, then converted once
    // with an explicit BT.709 matrix rather than FFmpeg's BT.601 default.
    // Green is plain SDR whatever the video was, so there is nothing to probe or tone-map.
    let colour = if out.green_screen {
        Colour::Sdr
    } else {
        Colour::of(&out.source_transfer, enc.hdr_pix_fmt)
    };
    let filter = colour.filter((w, h, out.fps), (bx, by), enc.pix_fmt, out.green_screen);
    let fps = out.fps.to_string();
    let size = format!("{bw}x{bh}");
    let length = format!("{duration:.3}");
    let mut args: Vec<&str> = vec!["-hide_banner", "-loglevel", "error", "-y"];
    args.extend(out.source_options.iter().map(String::as_str));
    args.extend(["-i", &out.source]);
    args.extend(["-f", "rawvideo", "-pix_fmt", "rgba", "-s", &size]);
    args.extend(["-framerate", &fps, "-i", "pipe:0"]);
    args.extend(["-filter_complex", &filter, "-map", "[v]"]);
    args.extend(if out.green_screen {
        &["-an"][..]
    } else {
        &["-map", "0:a?"][..]
    });
    args.extend(["-t", &length]);
    args.extend(colour.tags());
    args.extend(enc.args.iter().map(String::as_str));
    args.extend(audio_args(&out.codec));
    args.push(&out.output);
    Ok(Plan {
        args: args.into_iter().map(str::to_owned).collect(),
        frames: (duration * out.fps as f32).ceil() as u32,
        band: (bx, by, bw, bh),
        content_type: enc.content_type,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{FontBook, SceneInput};
    use serde_json::json;

    fn scene() -> Scene {
        let mut book = FontBook::new();
        book.add(include_bytes!("../fonts/Inter.ttf")).unwrap();
        let input: SceneInput = serde_json::from_value(json!({
            "width": 270, "height": 480,
            "transcript": { "duration": 2.0, "segments": [{ "words": [
                { "text": "hello", "start": 0.0, "end": 0.6 }] }] },
            "style": {
                "font": "Inter", "font_size": 48, "text_color": "#FFFFFF",
                "highlight_colors": ["#7C3AED"], "background": "none",
                "background_color": "#000000", "background_opacity": 0.0,
                "position_x": 0.5, "position_y": 0.8, "animation": "none",
                "words_per_line": 3, "stroke_width": 0, "stroke_color": "#000000",
                "shadow_blur": 0, "shadow_color": "#000000"
            }
        }))
        .unwrap();
        Scene::new(&book, input)
    }

    fn output(patch: serde_json::Value) -> Output {
        let mut value = json!({
            "source": "in.mp4", "output": "out.mp4", "duration": 2.0,
            "fps": 30, "codec": "h264", "crf": 15
        });
        for (k, v) in patch.as_object().unwrap() {
            value[k] = v.clone();
        }
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn the_plan_lays_the_band_over_the_source_and_encodes_it() {
        let scene = scene();
        let plan = plan(&scene, &output(json!({}))).unwrap();
        let (bx, by, bw, bh) = scene.overlay_bounds();
        assert_eq!(plan.band, (bx, by, bw, bh));
        assert_eq!(plan.frames, 60);
        assert_eq!(plan.content_type, "video/mp4");
        let args = plan.args.join(" ");
        assert!(args.starts_with("-hide_banner -loglevel error -y -i in.mp4 -f rawvideo"));
        assert!(args.contains(&format!("-s {bw}x{bh} -framerate 30 -i pipe:0")));
        assert!(args.contains(&format!("overlay=x={bx}:y={by}:")));
        assert!(args.contains("-map 0:a? -t 2.000 -colorspace bt709"));
        assert!(args.ends_with(
            "-c:v libx264 -preset medium -crf 15 -c:a aac -b:a 192k -movflags +faststart out.mp4"
        ));
    }

    #[test]
    fn the_plan_puts_source_options_before_the_source_and_drops_sound_over_green() {
        let plan = plan(
            &scene(),
            &output(json!({
                "source_options": ["-rw_timeout", "5"], "green_screen": true,
                "source_transfer": "smpte2084", "codec": "prores", "crf": null
            })),
        )
        .unwrap();
        let args = plan.args.join(" ");
        assert!(args.contains("-y -rw_timeout 5 -i in.mp4"));
        assert!(args.contains("-map [v] -an -t"));
        assert!(
            args.contains("-color_trc bt709"),
            "green is SDR whatever the source"
        );
        assert_eq!(plan.content_type, "video/quicktime");
    }

    #[test]
    fn the_plan_refuses_what_cannot_be_encoded() {
        assert!(plan(&scene(), &output(json!({ "crf": null }))).is_err());
        assert!(plan(&scene(), &output(json!({ "codec": "av1" }))).is_err());
        assert!(plan(&scene(), &output(json!({ "fps": 0 }))).is_err());
        let short = plan(&scene(), &output(json!({ "duration": 0.0 }))).unwrap();
        assert_eq!(short.frames, 1, "at least one frame");
    }

    #[test]
    fn hdr_is_kept_where_the_codec_can_carry_it_and_tone_mapped_where_not() {
        assert!(matches!(
            Colour::of("bt709", Some("yuv420p10le")),
            Colour::Sdr
        ));
        assert!(matches!(Colour::of("", None), Colour::Sdr));
        assert!(matches!(Colour::of("smpte2084", None), Colour::ToneMapped));
        let hlg = Colour::of("arib-std-b67", Some("yuv420p10le"));
        assert_eq!(hlg.tags()[5], "arib-std-b67");
        assert!(
            hlg.filter((1080, 1920, 30), (0, 0), "yuv420p", false)
                .contains("t=arib-std-b67")
        );
        assert_eq!(Colour::of("smpte2084", None).tags()[5], "bt709");
    }

    #[test]
    fn green_screen_replaces_the_video_with_solid_green() {
        let green = Colour::Sdr.filter((1080, 1920, 30), (0, 0), "yuv420p", true);
        assert!(green.starts_with("color=c=0x00FF00:s=1080x1920:r=30"));
        assert!(!green.contains("[0:v]"), "the video picture is not read");
        assert!(green.contains("overlay"), "the captions go over it");
        let plain = Colour::Sdr.filter((1080, 1920, 30), (0, 0), "yuv420p", false);
        assert!(plain.starts_with("[0:v]") && !plain.contains("0x00FF00"));
    }

    #[test]
    fn the_captions_are_laid_over_the_video_where_they_were_cut_from() {
        for colour in [
            Colour::Sdr,
            Colour::ToneMapped,
            Colour::of("smpte2084", Some("yuv420p10le")),
        ] {
            let graph = colour.filter((1080, 1920, 30), (64, 1500), "yuv420p", false);
            assert!(graph.contains("overlay=x=64:y=1500:"), "{graph}");
        }
    }
}
