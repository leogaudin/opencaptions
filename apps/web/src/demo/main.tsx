import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { languageReady } from "@/lib/i18n";
import { setSources } from "@/lib/sources";
import { disableSaving } from "@/store/editorStore";
import "../index.css";
import { DemoApp } from "./DemoApp";

// No API here: the clips and the fonts are static files, and nothing is saved.
setSources({
  video: (id) => `/demo/clips/${id}.mp4`,
  font: (family) => `/demo/fonts/${family.replace(/[^A-Za-z0-9]+/g, "-")}.ttf`,
});
disableSaving();

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Root element #root not found");

languageReady.then(() => {
  createRoot(rootElement).render(
    <StrictMode>
      <DemoApp />
    </StrictMode>,
  );
});
