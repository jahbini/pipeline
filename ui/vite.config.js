import { sveltekit } from "@sveltejs/kit/vite";
import coffee from "vite-plugin-coffee";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [
    coffee({
      jsx: false,
      bare: true
    }),
    sveltekit()
  ]
});
