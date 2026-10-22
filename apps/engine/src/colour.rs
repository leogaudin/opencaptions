//! How a render treats colour: what the source is, what the output codec takes, and the
//! FFmpeg filters and tags that follow.

/// How a render treats colour, decided by the source and the output codec.
pub(crate) enum Colour {
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
pub(crate) const SDR_WHITE_NITS: u32 = 203;

/// The scale that puts caption white on that same reference white, measured: it
/// lands within 1% of BT.2408 graphics white in both PQ and HLG.
pub(crate) const CAPTION_NPL: u32 = 160;

impl Colour {
    pub(crate) fn of(transfer: &str, hdr_pix_fmt: Option<&'static str>) -> Self {
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
    pub(crate) fn filter(
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

    pub(crate) fn tags(&self) -> [&str; 6] {
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
