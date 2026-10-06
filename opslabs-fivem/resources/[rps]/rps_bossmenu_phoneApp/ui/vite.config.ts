import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ command }) => ({
    base: command === 'build' ? '/ui/dist' : '',
    plugins: [react()],
    define: {
        global: 'window'
    },
    build: {
        outDir: 'dist',
        sourcemap: false
    },
    server: {
        port: 3000,
        open: true
    }
}))
