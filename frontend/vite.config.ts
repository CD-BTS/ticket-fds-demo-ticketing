import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// 개발 환경에서 /api 요청을 Spring Boot(8080)로 프록시 (CORS 회피)
// DEMO_API_TARGET 으로 대상 서버를 바꿀 수 있다 (예: e2e 격리 환경의 Demo 백엔드 http://localhost:18081)
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '')
  return {
    plugins: [react()],
    server: {
      proxy: {
        '/api': { target: env.DEMO_API_TARGET || 'http://localhost:8080', changeOrigin: true },
      },
    },
  }
})
