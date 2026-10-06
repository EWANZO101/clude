// Ambient globals injected into every LB Phone custom app's iframe at
// runtime — not implemented in this project, just declared here so
// TypeScript knows about them. Only the two this app actually uses.
declare function fetchNui<T = any>(eventName: string, data?: any): Promise<T>
declare function useNuiEvent<T = any>(action: string, handler: (data: T) => void): void

interface Window {
    invokeNative?: unknown
}
