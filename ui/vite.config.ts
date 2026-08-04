import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: false,
  },
  build: {
    // Build into the Elixir app's `priv/`, which is what serves the bundle in
    // production: `Manifold.Web.Router` reads it via `Application.app_dir/2`, so
    // it resolves from any working directory and inside a release. `emptyOutDir`
    // has to be explicit because the directory is outside Vite's root.
    outDir: "../priv/static",
    emptyOutDir: true,
  },
});
