import { defineConfig } from 'vite';

export default defineConfig({
  // 相對路徑，部署到 GitHub Pages 的子路徑也能正常載入
  base: './',
  build: {
    rollupOptions: {
      input: {
        main: 'index.html',
        admin: 'admin.html',
      },
    },
  },
});
