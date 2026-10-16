import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://sidewave.dev',
  output: 'static',
  compressHTML: true,
  outDir: '../docs',
  build: {
    assets: '_astro'
  },
  server: {
    port: 4322
  }
});
