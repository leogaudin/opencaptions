import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { resumeDownloads } from "./lib/downloads";
import { languageReady } from "./lib/i18n";
import "./index.css";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Root element #root not found");
}

resumeDownloads();

// Wait for the language's translations (a few KB), so the first paint is not English.
languageReady.then(() => {
  createRoot(rootElement).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
});
