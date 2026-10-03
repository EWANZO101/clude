export interface Grade {
    level: number
    name: string
    id: number
    label: string
}

export interface EmployeePerms {
    manage?: boolean
    hire?: boolean
    fire?: boolean
    bonus?: boolean
    deposit?: boolean
    withdraw?: boolean
    ledger?: boolean
    webshop?: boolean
    master?: boolean
    all_perms?: boolean
}

export interface Employee {
    id: string
    name: string
    rank: string
    wage: number
    perms: EmployeePerms
}

export interface NearbyPlayer {
    id: number
    src: number
    cid: string
    name: string
}

export interface GetEmployeesResult {
    canManage: boolean
    employees: Employee[]
    grades: Grade[]
    myCid?: string
    isOwner?: boolean
    isBoss?: boolean
}

export const PERM_KEYS: Array<{ key: keyof EmployeePerms; label: string }> = [
    { key: 'manage', label: 'Manage Employees' },
    { key: 'hire', label: 'Hire' },
    { key: 'fire', label: 'Fire' },
    { key: 'bonus', label: 'Bonus' },
    { key: 'deposit', label: 'Deposit' },
    { key: 'withdraw', label: 'Withdraw' },
    { key: 'ledger', label: 'Ledger' },
    { key: 'webshop', label: 'Webshop' }
]
