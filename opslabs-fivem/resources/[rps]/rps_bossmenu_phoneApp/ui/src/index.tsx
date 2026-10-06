import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './colors.css'
import './index.css'

const devMode = !window?.['invokeNative']

const root = ReactDOM.createRoot(document.getElementById('root') as HTMLElement)

const renderApp = () => {
    document.body.style.visibility = 'visible'
    root.render(
        <React.StrictMode>
            <App />
        </React.StrictMode>
    )
}

if (devMode) {
    // No lb-phone host in the browser — polyfill fetchNui/useNuiEvent with
    // fake data so `npm run dev` is still useful for UI work.
    ;(window as any).fetchNui = async (event: string) => {
        if (event === 'getEmployees') {
            return {
                canManage: true,
                myCid: 'ABC123',
                isOwner: true,
                isBoss: true,
                grades: [
                    { level: 0, name: 'Trainee', id: 0, label: 'Trainee' },
                    { level: 1, name: 'Worker', id: 1, label: 'Worker' },
                    { level: 2, name: 'Manager', id: 2, label: 'Manager' },
                    { level: 3, name: 'Boss', id: 3, label: 'Boss' }
                ],
                employees: [
                    { id: 'ABC123', name: 'Stefan Roodt', rank: 'Boss', wage: 100, perms: { master: true, all_perms: true } },
                    { id: 'DEF456', name: 'pierre jordaam', rank: 'Worker', wage: 75, perms: {} }
                ]
            }
        }
        if (event === 'getNearbyPlayers') {
            return [{ id: 5, src: 5, cid: 'GHI789', name: 'John Tester' }]
        }
        return 'ok'
    }
    ;(window as any).useNuiEvent = () => {}

    renderApp()
} else {
    window.addEventListener('message', (event) => {
        if (event.data === 'componentsLoaded') renderApp()
    })
}
