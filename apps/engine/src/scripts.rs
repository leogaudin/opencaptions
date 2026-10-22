//! Which fonts a transcript needs beyond the bundled ones. The bundled faces cover Latin, Greek,
//! Cyrillic, Arabic, Hebrew, Devanagari and Thai; Chinese, Japanese, Korean and the other
//! scripts' fonts are too large to ship, so a host fetches the families named here (from Google
//! Fonts, as it does for a style's own font) and registers them. One rule for every host: the
//! preview, the phone and the render server ask the same function. `testdata/script_fonts.json`
//! holds its cases.

/// A script's letters, and the family that draws them.
struct Script {
    family: &'static str,
    ranges: &'static [(u32, u32)],
}

const SCRIPTS: &[Script] = &[
    Script {
        family: "Noto Sans Bengali",
        ranges: &[(0x0980, 0x09FF)],
    },
    Script {
        family: "Noto Sans Gurmukhi",
        ranges: &[(0x0A00, 0x0A7F)],
    },
    Script {
        family: "Noto Sans Gujarati",
        ranges: &[(0x0A80, 0x0AFF)],
    },
    Script {
        family: "Noto Sans Tamil",
        ranges: &[(0x0B80, 0x0BFF)],
    },
    Script {
        family: "Noto Sans Telugu",
        ranges: &[(0x0C00, 0x0C7F)],
    },
    Script {
        family: "Noto Sans Kannada",
        ranges: &[(0x0C80, 0x0CFF)],
    },
    Script {
        family: "Noto Sans Malayalam",
        ranges: &[(0x0D00, 0x0D7F)],
    },
    Script {
        family: "Noto Sans Sinhala",
        ranges: &[(0x0D80, 0x0DFF)],
    },
    Script {
        family: "Noto Sans Lao",
        ranges: &[(0x0E80, 0x0EFF)],
    },
    Script {
        family: "Noto Sans Myanmar",
        ranges: &[(0x1000, 0x109F)],
    },
    Script {
        family: "Noto Sans Georgian",
        ranges: &[(0x10A0, 0x10FF)],
    },
    Script {
        family: "Noto Sans Ethiopic",
        ranges: &[(0x1200, 0x137F)],
    },
    Script {
        family: "Noto Sans Khmer",
        ranges: &[(0x1780, 0x17FF)],
    },
    Script {
        family: "Noto Sans Armenian",
        ranges: &[(0x0530, 0x058F)],
    },
];

/// A script the engine ships a face for: the file in `fonts/`, the family it declares, and the
/// letters it draws. A host with little to spare (the browser) may fetch such a face only when a
/// caption has letters of its script, so it is listed here: `script_faces` says which a text
/// needs. The files are the ones named `NotoSans*` (a test holds the table to the folder).
pub struct ScriptFace {
    pub file: &'static str,
    pub family: &'static str,
    ranges: &'static [(u32, u32)],
}

pub const SCRIPT_FACES: &[ScriptFace] = &[
    ScriptFace {
        file: "NotoSansArabic.ttf",
        family: "Noto Sans Arabic",
        ranges: &[
            (0x0600, 0x06FF),
            (0x0750, 0x077F),
            (0x0870, 0x08FF),
            (0xFB50, 0xFDFF),
            (0xFE70, 0xFEFF),
        ],
    },
    ScriptFace {
        file: "NotoSansDevanagari.ttf",
        family: "Noto Sans Devanagari",
        ranges: &[(0x0900, 0x097F), (0xA8E0, 0xA8FF)],
    },
    ScriptFace {
        file: "NotoSansHebrew.ttf",
        family: "Noto Sans Hebrew",
        ranges: &[(0x0590, 0x05FF), (0xFB1D, 0xFB4F)],
    },
    ScriptFace {
        file: "NotoSansThai.ttf",
        family: "Noto Sans Thai",
        ranges: &[(0x0E00, 0x0E7F)],
    },
];

/// The shipped script faces whose letters appear in `texts`, in the table's order.
pub fn script_faces<'a>(texts: impl Iterator<Item = &'a str>) -> Vec<&'static ScriptFace> {
    let chars: Vec<char> = texts
        .flat_map(str::chars)
        .filter(|c| !c.is_ascii())
        .collect();
    SCRIPT_FACES
        .iter()
        .filter(|face| chars.iter().any(|&c| within(c, face.ranges)))
        .collect()
}

const KANA: &[(u32, u32)] = &[(0x3040, 0x30FF), (0x31F0, 0x31FF), (0xFF66, 0xFF9F)];
const HANGUL: &[(u32, u32)] = &[(0x1100, 0x11FF), (0x3130, 0x318F), (0xAC00, 0xD7AF)];
const HAN: &[(u32, u32)] = &[
    (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF),
    (0xF900, 0xFAFF),
    (0x20000, 0x2A6DF),
];

fn within(c: char, ranges: &[(u32, u32)]) -> bool {
    ranges.iter().any(|&(a, b)| (a..=b).contains(&(c as u32)))
}

/// The families whose letters appear in `texts`, in order of first appearance. Han characters are
/// drawn in the Japanese face when the text has kana or the language is Japanese, in the Korean
/// face when it has hangul or the language is Korean, and otherwise in Chinese (Traditional for
/// `zh-TW`, `zh-HK` and `zh-Hant`).
pub fn fallback_families<'a>(texts: impl Iterator<Item = &'a str>, language: &str) -> Vec<String> {
    let mut chars: Vec<char> = Vec::new();
    for text in texts {
        chars.extend(text.chars().filter(|c| !c.is_ascii()));
    }
    let language = language.to_ascii_lowercase();
    let has = |ranges: &[(u32, u32)]| chars.iter().any(|&c| within(c, ranges));
    let (kana, hangul) = (has(KANA), has(HANGUL));
    let mut out: Vec<String> = Vec::new();
    let mut push = |family: &str| {
        if !out.iter().any(|f| f == family) {
            out.push(family.to_string());
        }
    };
    for &c in &chars {
        if within(c, KANA) {
            push("Noto Sans JP");
        } else if within(c, HANGUL) {
            push("Noto Sans KR");
        } else if within(c, HAN) {
            let family = if kana || language.starts_with("ja") {
                "Noto Sans JP"
            } else if hangul || language.starts_with("ko") {
                "Noto Sans KR"
            } else if ["zh-tw", "zh-hk", "zh-hant", "zh_tw", "zh_hk"]
                .iter()
                .any(|p| language.starts_with(p))
            {
                "Noto Sans TC"
            } else {
                "Noto Sans SC"
            };
            push(family);
        } else if let Some(script) = SCRIPTS.iter().find(|s| within(c, s.ranges)) {
            push(script.family);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fonts::FontBook;

    #[test]
    fn the_script_faces_are_the_noto_files_and_declare_their_families() {
        let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fonts");
        let mut files: Vec<String> = std::fs::read_dir(&folder)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .filter(|n| n.starts_with("NotoSans") && n.ends_with(".ttf"))
            .collect();
        files.sort();
        let listed: Vec<&str> = SCRIPT_FACES.iter().map(|f| f.file).collect();
        assert_eq!(files, listed, "the table lists the NotoSans* files, sorted");
        for face in SCRIPT_FACES {
            let data = std::fs::read(folder.join(face.file)).unwrap();
            let mut book = FontBook::new();
            assert_eq!(
                book.add(Box::leak(data.into_boxed_slice())).as_deref(),
                Some(face.family),
                "{}",
                face.file
            );
        }
    }

    #[test]
    fn a_text_needs_the_faces_of_its_scripts_only() {
        let needs = |text: &str| -> Vec<&str> {
            script_faces([text].into_iter())
                .iter()
                .map(|f| f.family)
                .collect()
        };
        assert!(needs("Hello, déjà vu, Привет, γειά").is_empty());
        assert_eq!(needs("مرحبا"), ["Noto Sans Arabic"]);
        assert_eq!(
            needs("שלום hello नमस्ते"),
            ["Noto Sans Devanagari", "Noto Sans Hebrew"]
        );
        assert_eq!(needs("สวัสดี"), ["Noto Sans Thai"]);
        assert!(needs("你好").is_empty(), "Han is fetched, not shipped");
    }

    /// The cases the API's copy of the rule is held to as well.
    #[test]
    fn the_shared_cases_hold() {
        let cases: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../testdata/script_fonts.json")).unwrap();
        assert!(cases.len() >= 10);
        for case in cases {
            let words: Vec<&str> = case["words"]
                .as_array()
                .unwrap()
                .iter()
                .map(|w| w.as_str().unwrap())
                .collect();
            let language = case["language"].as_str().unwrap();
            let expected: Vec<&str> = case["families"]
                .as_array()
                .unwrap()
                .iter()
                .map(|f| f.as_str().unwrap())
                .collect();
            assert_eq!(
                fallback_families(words.iter().copied(), language),
                expected,
                "{words:?} in {language:?}"
            );
        }
    }
}
