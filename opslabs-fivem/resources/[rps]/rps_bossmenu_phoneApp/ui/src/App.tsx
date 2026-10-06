import { useEffect, useState } from 'react'
import './App.css'
import { Employee, EmployeePerms, GetEmployeesResult, Grade, NearbyPlayer, PERM_KEYS } from './types'

type ModalMode = null | { type: 'manage'; emp: Employee } | { type: 'bonus'; emp: Employee } | { type: 'fire'; emp: Employee } | { type: 'hire' }

const App = () => {
    const [loading, setLoading] = useState(true)
    const [data, setData] = useState<GetEmployeesResult | null>(null)
    const [modal, setModal] = useState<ModalMode>(null)

    const refresh = async () => {
        const result = await fetchNui<GetEmployeesResult>('getEmployees')
        setData(result)
        setLoading(false)
    }

    useEffect(() => {
        refresh()
    }, [])

    if (loading) {
        return (
            <div className="app">
                <div className="empty-state">Loading…</div>
            </div>
        )
    }

    if (!data || !data.canManage) {
        return (
            <div className="app">
                <div className="empty-state">
                    <div style={{ fontWeight: 700, fontSize: '1rem' }}>No Access</div>
                    <div>Only the business owner or boss can manage staff from here.</div>
                </div>
            </div>
        )
    }

    return (
        <div className="app">
            <div className="header">
                <div>
                    <h1>Staff Roster</h1>
                    <div className="subtitle">{data.employees.length} Active Employees</div>
                </div>
                <button className="hire-btn" onClick={() => setModal({ type: 'hire' })}>
                    + Hire Nearby
                </button>
            </div>

            <div className="list">
                {data.employees.length === 0 ? (
                    <div className="empty-state">No employees found.</div>
                ) : (
                    data.employees.map((emp) => (
                        <EmployeeRow key={emp.id} emp={emp} myCid={data.myCid} onOpen={(type) => setModal({ type, emp } as ModalMode)} />
                    ))
                )}
            </div>

            {modal?.type === 'manage' && (
                <ManageModal
                    emp={modal.emp}
                    grades={data.grades}
                    isOwner={!!data.isOwner}
                    onClose={() => setModal(null)}
                    onSaved={async () => {
                        setModal(null)
                        await refresh()
                    }}
                />
            )}

            {modal?.type === 'bonus' && (
                <BonusModal
                    emp={modal.emp}
                    onClose={() => setModal(null)}
                    onSaved={async () => {
                        setModal(null)
                        await refresh()
                    }}
                />
            )}

            {modal?.type === 'fire' && (
                <FireModal
                    emp={modal.emp}
                    onClose={() => setModal(null)}
                    onFired={async () => {
                        setModal(null)
                        await refresh()
                    }}
                />
            )}

            {modal?.type === 'hire' && (
                <HireModal
                    grades={data.grades}
                    onClose={() => setModal(null)}
                    onSent={() => setModal(null)}
                />
            )}
        </div>
    )
}

const EmployeeRow = ({ emp, myCid, onOpen }: { emp: Employee; myCid?: string; onOpen: (type: 'manage' | 'bonus' | 'fire') => void }) => (
    <div className="emp-row">
        <div className="emp-info">
            <div className="emp-avatar">{emp.name ? emp.name.charAt(0).toUpperCase() : '?'}</div>
            <div style={{ minWidth: 0 }}>
                <div className="emp-name">{emp.name}</div>
                <div className="emp-meta">
                    {emp.rank} • ${emp.wage}/hr
                </div>
            </div>
        </div>
        <div className="emp-actions">
            <button className="icon-btn manage" title="Manage" onClick={() => onOpen('manage')}>
                ⚙
            </button>
            <button className="icon-btn bonus" title="Bonus" onClick={() => onOpen('bonus')}>
                $
            </button>
            {emp.id !== myCid && (
                <button className="icon-btn fire" title="Fire" onClick={() => onOpen('fire')}>
                    ✕
                </button>
            )}
        </div>
    </div>
)

const ManageModal = ({
    emp,
    grades,
    isOwner,
    onClose,
    onSaved
}: {
    emp: Employee
    grades: Grade[]
    isOwner: boolean
    onClose: () => void
    onSaved: () => void
}) => {
    const [rank, setRank] = useState(emp.rank)
    const [wage, setWage] = useState(emp.wage)
    const [perms, setPerms] = useState<EmployeePerms>(emp.perms || {})
    const [saving, setSaving] = useState(false)

    const togglePerm = (key: keyof EmployeePerms) => setPerms((p) => ({ ...p, [key]: !p[key] }))

    const save = async () => {
        setSaving(true)
        await fetchNui('manageEmployee', { id: emp.id, rank, wage: Number(wage) || 0, perms })
        onSaved()
    }

    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal" onClick={(e) => e.stopPropagation()}>
                <h2>Manage {emp.name}</h2>

                <div className="field">
                    <label>Rank</label>
                    <select value={rank} onChange={(e) => setRank(e.target.value)}>
                        {grades.length > 0 ? (
                            grades.map((g) => (
                                <option key={g.id} value={g.name}>
                                    {g.label}
                                </option>
                            ))
                        ) : (
                            <option value={rank}>{rank}</option>
                        )}
                    </select>
                </div>

                <div className="field">
                    <label>Wage ($/hr)</label>
                    <input type="number" value={wage} onChange={(e) => setWage(Number(e.target.value))} />
                </div>

                <div className="field">
                    <label>Permissions</label>
                    <div className="perm-list">
                        {isOwner && (
                            <label style={{ color: 'var(--danger)', fontWeight: 700 }}>
                                <input type="checkbox" checked={!!perms.master} onChange={() => togglePerm('master')} />
                                Master Override (All)
                            </label>
                        )}
                        {PERM_KEYS.map(({ key, label }) => (
                            <label key={key} style={{ opacity: perms.master ? 0.5 : 1 }}>
                                <input type="checkbox" disabled={!!perms.master} checked={!!perms[key]} onChange={() => togglePerm(key)} />
                                {label}
                            </label>
                        ))}
                    </div>
                </div>

                <div className="modal-actions">
                    <button className="btn-cancel" onClick={onClose} disabled={saving}>
                        Cancel
                    </button>
                    <button className="btn-primary" onClick={save} disabled={saving}>
                        {saving ? 'Saving…' : 'Save'}
                    </button>
                </div>
            </div>
        </div>
    )
}

const BonusModal = ({ emp, onClose, onSaved }: { emp: Employee; onClose: () => void; onSaved: () => void }) => {
    const [amount, setAmount] = useState('')
    const [saving, setSaving] = useState(false)

    const save = async () => {
        const n = Number(amount)
        if (!n || n <= 0) return
        setSaving(true)
        await fetchNui('giveBonus', { id: emp.id, amount: n })
        onSaved()
    }

    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal" onClick={(e) => e.stopPropagation()}>
                <h2>Bonus for {emp.name}</h2>
                <div className="field">
                    <label>Amount ($)</label>
                    <input type="number" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0" />
                </div>
                <div className="modal-actions">
                    <button className="btn-cancel" onClick={onClose} disabled={saving}>
                        Cancel
                    </button>
                    <button className="btn-primary" onClick={save} disabled={saving}>
                        {saving ? 'Paying…' : 'Pay Bonus'}
                    </button>
                </div>
            </div>
        </div>
    )
}

const FireModal = ({ emp, onClose, onFired }: { emp: Employee; onClose: () => void; onFired: () => void }) => {
    const [firing, setFiring] = useState(false)

    const fire = async () => {
        setFiring(true)
        await fetchNui('fireEmployee', { id: emp.id })
        onFired()
    }

    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal" onClick={(e) => e.stopPropagation()}>
                <h2 style={{ color: 'var(--danger)' }}>Fire Employee</h2>
                <div className="hint">Are you sure you want to terminate {emp.name}? This action cannot be undone.</div>
                <div className="modal-actions">
                    <button className="btn-cancel" onClick={onClose} disabled={firing}>
                        Cancel
                    </button>
                    <button className="btn-danger" onClick={fire} disabled={firing}>
                        {firing ? 'Terminating…' : 'Terminate'}
                    </button>
                </div>
            </div>
        </div>
    )
}

const HireModal = ({ grades, onClose, onSent }: { grades: Grade[]; onClose: () => void; onSent: () => void }) => {
    const [nearby, setNearby] = useState<NearbyPlayer[]>([])
    const [scanning, setScanning] = useState(true)
    const [selected, setSelected] = useState<NearbyPlayer | null>(null)
    const [rank, setRank] = useState(grades[0]?.name || 'Worker')
    const [wage, setWage] = useState(500)
    const [sending, setSending] = useState(false)

    useEffect(() => {
        fetchNui<NearbyPlayer[]>('getNearbyPlayers').then((players) => {
            setNearby(players || [])
            setScanning(false)
        })
    }, [])

    const send = async () => {
        if (!selected) return
        setSending(true)
        await fetchNui('sendJobOffer', { player: selected.src, rank, wage: Number(wage) || 0 })
        onSent()
    }

    return (
        <div className="modal-overlay" onClick={onClose}>
            <div className="modal" onClick={(e) => e.stopPropagation()}>
                <h2>Hire Nearby Player</h2>

                <div className="field">
                    <label>Nearby Players</label>
                    {scanning ? (
                        <div className="hint">Scanning…</div>
                    ) : nearby.length === 0 ? (
                        <div className="hint">No one nearby.</div>
                    ) : (
                        <div className="nearby-list">
                            {nearby.map((p) => (
                                <div
                                    key={p.src}
                                    className={`nearby-item${selected?.src === p.src ? ' selected' : ''}`}
                                    onClick={() => setSelected(p)}
                                >
                                    {p.name}
                                </div>
                            ))}
                        </div>
                    )}
                </div>

                <div className="field">
                    <label>Rank</label>
                    <select value={rank} onChange={(e) => setRank(e.target.value)}>
                        {grades.length > 0 ? (
                            grades.map((g) => (
                                <option key={g.id} value={g.name}>
                                    {g.label}
                                </option>
                            ))
                        ) : (
                            <option value="Worker">Worker</option>
                        )}
                    </select>
                </div>

                <div className="field">
                    <label>Wage ($/hr)</label>
                    <input type="number" value={wage} onChange={(e) => setWage(Number(e.target.value))} />
                </div>

                <div className="modal-actions">
                    <button className="btn-cancel" onClick={onClose} disabled={sending}>
                        Cancel
                    </button>
                    <button className="btn-primary" onClick={send} disabled={sending || !selected}>
                        {sending ? 'Sending…' : 'Send Offer'}
                    </button>
                </div>
            </div>
        </div>
    )
}

export default App
