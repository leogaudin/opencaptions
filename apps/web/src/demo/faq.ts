/**
 * The questions the page answers, in plain sentences. They are on the page, and the same words are
 * in its structured data (FAQPage), which search engines and AI assistants read: keep each answer
 * true on its own, since it may be quoted without the rest. `msg` marks them for translation; the
 * page shows them with `t`.
 */
import { msg } from "@/lib/i18n";

export const FAQ: readonly { q: string; a: string }[] = [
  {
    q: msg("What is OpenCaptions?"),
    a: msg(
      "OpenCaptions is free, open-source software that adds animated, word-by-word captions to videos. It transcribes the speech with a model you choose, such as Whisper, Parakeet or Apple Speech, lets you style and correct every caption, and exports a captioned video or subtitle files. It runs on your iPhone and on your own server.",
    ),
  },
  {
    q: msg("Is it free?"),
    a: msg(
      "The code is free and open source, and hosting the web editor yourself costs nothing but your own hardware. The iPhone app is free to use, with an optional one-time Pro purchase and no subscription.",
    ),
  },
  {
    q: msg("Does it upload my videos?"),
    a: msg(
      "Not unless you choose to. On the iPhone the speech is transcribed on the device, and when you host OpenCaptions yourself your videos stay on your own server. There is no tracking and no analytics.",
    ),
  },
  {
    q: msg("Which languages does it support?"),
    a: msg(
      "Whisper transcribes about 100 languages and Parakeet 25 European ones, and Apple Speech covers the languages iOS offers. Captions can be drawn in Latin, Cyrillic, Arabic, Hebrew, Indic, Thai and CJK scripts, and the interface is available in 13 languages.",
    ),
  },
  {
    q: msg("How do I host it myself?"),
    a: msg(
      "With Docker: download one file, start it with a single command, and open the editor in your browser. A GPU is optional and makes transcription faster.",
    ),
  },
  {
    q: msg("Which formats can I export?"),
    a: msg(
      "A captioned video as MP4, WebM or ProRes, subtitle files as SRT or VTT, a JSON transcript, or only the captions on a green screen to key out in your own video editor.",
    ),
  },
  {
    q: msg("How is it different from other caption tools?"),
    a: msg(
      "It is open source and you can run it yourself, so your videos stay with you and there is no subscription. The iPhone app works on the device, and the preview is the export: one Rust engine draws the captions in the browser, on the server and on the phone.",
    ),
  },
  {
    q: msg("What is the license?"),
    a: msg(
      "AGPL-3.0. You can use, study, change and share it. If you run a modified version as a service, you must offer its users the source code.",
    ),
  },
];
