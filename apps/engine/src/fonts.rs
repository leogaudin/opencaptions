//! Fonts are data, not code. A bundled font is registered under the family its
//! own name table declares, so adding one means dropping a file in. A requested
//! font (one a style names that is not bundled) is registered under the name it
//! was asked for.
//!
//! Lookup is the same rule everywhere: the first face with the family's name
//! wins, and bundled faces are registered first. Glyph fallback only ever
//! reaches bundled faces, so the fonts another style happened to load can never
//! change a frame.

use rustybuzz::ttf_parser::{Tag, name_id};
use rustybuzz::{Face, Variation};

/// Caption text is drawn heavy. Variable faces are set to this on their weight
/// axis; static faces draw as designed.
const WEIGHT: f32 = 800.0;

/// The application's default face, used when a style names one that is not installed.
const FALLBACK_FAMILY: &str = "Inter";

#[derive(Clone)]
struct Entry<'a> {
    family: String,
    face: Face<'a>,
    bundled: bool,
}

#[derive(Clone, Default)]
pub struct FontBook<'a> {
    faces: Vec<Entry<'a>>,
}

fn family_of(face: &Face) -> Option<String> {
    let names = face.names();
    [name_id::TYPOGRAPHIC_FAMILY, name_id::FAMILY]
        .iter()
        .find_map(|&id| {
            names
                .into_iter()
                .find(|n| n.name_id == id && n.is_unicode())?
                .to_string()
        })
}

fn parse(data: &[u8]) -> Option<Face<'_>> {
    let mut face = Face::from_slice(data, 0)?;
    face.set_variations(&[Variation {
        tag: Tag::from_bytes(b"wght"),
        value: WEIGHT,
    }]);
    Some(face)
}

impl<'a> FontBook<'a> {
    pub const fn new() -> Self {
        Self { faces: Vec::new() }
    }

    /// Register a bundled font and return its family, or `None` if it is not a font.
    pub fn add(&mut self, data: &'a [u8]) -> Option<String> {
        let face = parse(data)?;
        let family = family_of(&face)?;
        self.faces.push(Entry {
            family: family.clone(),
            face,
            bundled: true,
        });
        Some(family)
    }

    /// Register a font a style asked for, under that name. Returns whether it parsed.
    pub fn add_requested(&mut self, family: &str, data: &'a [u8]) -> bool {
        parse(data)
            .map(|face| {
                self.faces.push(Entry {
                    family: family.into(),
                    face,
                    bundled: false,
                })
            })
            .is_some()
    }

    /// Bundled families, in registration order.
    pub fn families(&self) -> Vec<&str> {
        self.faces
            .iter()
            .filter(|e| e.bundled)
            .fold(Vec::new(), |mut out, e| {
                if !out.contains(&e.family.as_str()) {
                    out.push(e.family.as_str());
                }
                out
            })
    }

    pub fn has(&self, family: &str) -> bool {
        self.find(family).is_some()
    }

    pub fn is_empty(&self) -> bool {
        self.faces.is_empty()
    }

    fn find(&self, family: &str) -> Option<usize> {
        self.faces
            .iter()
            .position(|e| e.family.eq_ignore_ascii_case(family))
    }

    /// The face for `family`, else the default face, else the first registered.
    pub fn primary(&self, family: &str) -> usize {
        self.find(family)
            .or_else(|| self.find(FALLBACK_FAMILY))
            .unwrap_or(0)
    }

    /// `primary` when it can draw every character of `text`, else the first
    /// bundled face that can, else `primary` so the missing glyphs show as such.
    pub fn for_text(&self, primary: usize, text: &str) -> usize {
        let covers = |i: usize| {
            let face = &self.faces[i].face;
            text.chars()
                .filter(|c| !c.is_whitespace())
                .all(|c| face.glyph_index(c).is_some())
        };
        if covers(primary) {
            return primary;
        }
        (0..self.faces.len())
            .find(|&i| self.faces[i].bundled && covers(i))
            .unwrap_or(primary)
    }

    pub fn face(&self, i: usize) -> &Face<'a> {
        &self.faces[i].face
    }
}
