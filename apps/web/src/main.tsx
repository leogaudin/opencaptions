import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { resumeDownloads } from "./lib/downloads";
import "./index.css";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Root element #root not found");
}

resumeDownloads();

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
