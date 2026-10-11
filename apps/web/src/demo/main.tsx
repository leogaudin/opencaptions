import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { getLanguage, languageReady, setLanguage } from "@/lib/i18n";
import { setSources } from "@/lib/sources";
import { disableSaving } from "@/store/editorStore";
import "../index.css";
import { DemoApp } from "./DemoApp";
import { languageFromPath, pagePath } from "./pages";

// No API here: the clips and the fonts are static files, and nothing is saved.
setSources({
  video: (id) => `/demo/clips/${id}.mp4`,
  font: (family) => `/demo/fonts/${family.replace(/[^A-Za-z0-9]+/g, "-")}.ttf`,
});
disableSaving();

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Root element #root not found");

// The address names the language ("/fr/" is French). At "/", a visitor whose browser (or earlier
// choice) is another language goes to that language's page; a visitor who picked English stays.
const named = languageFromPath(location.pathname);
const wanted = getLanguage();
if (!named && location.pathname === "/" && wanted !== "en") {
  location.replace(pagePath(wanted) + location.search + location.hash);
} else {
  (named ? setLanguage(named, false) : languageReady).then(() => {
    createRoot(rootElement).render(
      <StrictMode>
        <DemoApp />
      </StrictMode>,
    );
  });
}
