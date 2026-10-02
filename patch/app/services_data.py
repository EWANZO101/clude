"""
Content for the six service-division pages (/services/<slug>).

Everything a service page needs lives here as plain data, rendered by the
single shared template `templates/services/detail.html`. To add or edit a
service, edit this dict only — no template changes required.

icon: heroicons-outline path `d` attribute (24x24 viewBox)
accent: hex used for this service's icons/gradients/badges via Tailwind
        arbitrary-value classes, e.g. bg-[--accent]
"""

SERVICES = {

    "website-development": {
        "order": 1,
        "eyebrow": "Division 01",
        "name": "Website Development",
        "short_name": "Web Development",
        "tagline": "Custom sites, dashboards and web apps — built, deployed, and maintained by one team.",
        "accent": "#2196f3",
        "icon": "M9.75 3.104v5.714a2.25 2.25 0 01-.659 1.591L5 14.5M9.75 3.104c-1.279.129-2.548.311-3.8.541.482.174.947.383 1.4.63M9.75 3.104c1.279.129 2.548.311 3.8.541M14.25 3.104v5.714c0 .597.237 1.17.659 1.591L19.8 14.9M14.25 3.104c1.279.129 2.548.311 3.8.541-.482.174-.947.383-1.4.63m0 0L21 6.75M4.5 14.5l1.5 6.5h12l1.5-6.5M4.5 14.5h15",
        "summary": "From marketing sites to full internal dashboards, we design, build, and ship on modern stacks — then keep it running.",
        "overview": (
            "We build custom websites and web applications end-to-end: design, development, deployment, and "
            "ongoing maintenance. Everything is hand-coded rather than templated together, deployed to "
            "infrastructure we control, and backed by the same ticket system as every other division — so "
            "changes and support requests never get lost in an inbox."
        ),
        "services": [
            "Custom websites", "Business websites", "Dashboards", "Landing pages",
            "E-commerce websites", "Web applications", "Website maintenance",
            "API integrations", "WordPress development",
        ],
        "tech_label": "Technologies",
        "tech": ["Flask", "React", "Next.js", "WordPress", "PostgreSQL", "Nginx"],
        "process": [
            ("Discovery", "We scope what you actually need — pages, data, integrations — before writing anything."),
            ("Design", "Wireframes and a visual direction that matches your brand, reviewed before development starts."),
            ("Build", "Hand-built front and back end, tested against real data, not placeholder content."),
            ("Launch", "Deployed to production with monitoring in place, DNS and SSL handled for you."),
            ("Support", "Maintenance, edits, and fixes handled through tickets with a visible history."),
        ],
        "packages": [
            ("Landing Page", "Single-page site for a service, product, or launch.", ["1–3 sections", "Mobile responsive", "Contact form", "Basic SEO"]),
            ("Business Website", "Multi-page site for an established business.", ["Up to 8 pages", "CMS-editable content", "Contact & booking forms", "Analytics setup"]),
            ("Web Application", "Custom dashboards, portals, or internal tools.", ["Custom data model", "User accounts", "API integrations", "Ongoing maintenance plan"]),
        ],
        "faqs": [
            ("Do you host the site too?", "Yes — most clients run through our Hosting division, but we can deploy to your own infrastructure if you prefer."),
            ("Can you take over an existing site?", "Yes. We'll audit what's there first and tell you honestly whether to extend it or rebuild."),
            ("What does maintenance cost?", "Depends on scope — raised and quoted per ticket, or as a fixed monthly plan for ongoing work."),
        ],
        "cta_label": "Open a Website Development Ticket",
    },

    "fivem-development": {
        "order": 2,
        "eyebrow": "Division 02",
        "name": "FiveM Development",
        "short_name": "FiveM Development",
        "tagline": "Custom scripts, MLOs, and full server builds for QBCore, ESX, and standalone frameworks.",
        "accent": "#a855f7",
        "icon": "M11.42 15.17L17.25 21A2.652 2.652 0 0021 17.25l-5.877-5.877M11.42 15.17l2.496-3.03c.317-.384.74-.626 1.208-.766M11.42 15.17l-4.655 5.653a2.548 2.548 0 11-3.586-3.586l6.837-5.63m5.108-.233c.35-.146.667-.363.928-.633l1.964-1.964a2.121 2.121 0 00-3-3l-1.964 1.964a2.121 2.121 0 00-.633.928m5.108-.233l-5.108.233m0 0l-4.293 4.293",
        "summary": "Scripts, maps, and full server builds for GTA V roleplay communities, built by someone who runs one.",
        "overview": (
            "We build custom FiveM content — resources, MLOs, maps, and full server setups — for QBCore, ESX, "
            "and standalone frameworks. Because we operate our own roleplay community, everything ships "
            "already tested against a live player base, not just a local dev server."
        ),
        "services": [
            "Custom FiveM scripts", "MLO development", "Custom maps", "Server builds",
            "Framework configuration", "Resource development", "Server optimisation",
            "Bug fixing", "Custom systems",
        ],
        "tech_label": "Frameworks",
        "tech": ["QBCore", "ESX", "Lua", "MLO", "Standalone"],
        "process": [
            ("Scope", "Tell us the framework, the feature, and how it should behave in-game."),
            ("Prototype", "Core logic built and tested privately before anything touches your live server."),
            ("Integrate", "Wired into your existing framework, permissions, and database structure."),
            ("Playtest", "Tested under real player load, not just solo — where most scripts actually break."),
            ("Deliver", "Resource handed over with docs, or installed directly if we manage your server."),
        ],
        "packages": [
            ("Single Script", "One feature or system built to spec.", ["Framework-matched", "Config file included", "Bug-fix window included"]),
            ("MLO / Map", "Custom interior or map edit.", ["Optimised collisions", "YMAP + interior handling", "Placement support"]),
            ("Full Server Build", "Framework setup through to launch-ready.", ["Framework configuration", "Core resource pack", "Optimisation pass", "Launch support"]),
        ],
        "faqs": [
            ("Do you work with ESX and QBCore?", "Yes, plus standalone builds for servers not running either framework."),
            ("Can you fix scripts someone else wrote?", "Usually — we'll review the code first and tell you if a rebuild is the better option."),
            ("Do you host FiveM servers too?", "Yes, through our Hosting division — game server hosting alongside script development."),
        ],
        "cta_label": "Open a FiveM Development Ticket",
    },

    "tech-support": {
        "order": 3,
        "eyebrow": "Division 03",
        "name": "Tech Support",
        "short_name": "Tech Support",
        "tagline": "Debugging, log analysis, and rapid fixes — remote support when something's actually broken.",
        "accent": "#f59e0b",
        "icon": "M9.75 3.104v5.714a2.25 2.25 0 01-.659 1.591L5 14.5m9.75-11.396c1.279.129 2.548.311 3.8.541M14.25 3.104v5.714c0 .597.237 1.17.659 1.591L19.8 14.9M9.75 3.104A24.301 24.301 0 0112 3c.995 0 1.973.055 2.936.164M14.25 3.104C11.328 4.062 9 6.44 9 9.375c0 1.657.746 3.14 1.913 4.121M12 21.75c-4.556 0-8.25-3.694-8.25-8.25 0-1.936.667-3.716 1.783-5.126m6.467 13.376a8.207 8.207 0 004.5-1.318m0 0a8.25 8.25 0 002.833-2.833",
        "summary": "Something's broken and you need it fixed — described clearly, triaged fast, worked until resolved.",
        "overview": (
            "When something breaks — a site error, a server misbehaving, a config gone wrong — Tech Support "
            "is where you describe the problem and we work it through with you. Every request runs through "
            "the same ticket system, with a visible timeline from 'reported' to 'resolved'."
        ),
        "services": [
            "Debugging", "Troubleshooting", "Error investigation", "Log analysis",
            "System diagnostics", "Performance issues", "Software problems",
            "Configuration problems", "Rapid fixes", "Remote support",
        ],
        "tech_label": "Specialities",
        "tech": ["Debugging", "Log Analysis", "Triage"],
        "process": [
            ("Describe", "Tell us what's happening, what changed, and what you've already tried."),
            ("Attach", "Upload logs, screenshots, or files relevant to the issue."),
            ("Triage", "We set a priority and give you a realistic response time."),
            ("Fix", "Worked live in the ticket — you see progress as it happens, not just a final answer."),
            ("Confirm", "Ticket stays open until you confirm it's actually resolved."),
        ],
        "faqs": [
            ("What counts as urgent?", "Anything taking a live site, server, or business system down. Flag it as Urgent when you open the ticket."),
            ("Do I need to know what's wrong?", "No — describe the symptoms. Diagnosing the actual cause is part of the job."),
            ("Is remote access required?", "Sometimes, for server-side issues. We'll always ask first and explain what we need access to."),
        ],
        "cta_label": "Open a Support Ticket",
    },

    "hosting": {
        "order": 4,
        "eyebrow": "Division 04",
        "name": "Hosting",
        "short_name": "Hosting",
        "tagline": "VPS, dedicated, and game server hosting — provisioned, migrated, and monitored for you.",
        "accent": "#22c55e",
        "icon": "M20.25 6.375c0 2.278-3.694 4.125-8.25 4.125S3.75 8.653 3.75 6.375m16.5 0c0-2.278-3.694-4.125-8.25-4.125S3.75 4.097 3.75 6.375m16.5 0v11.25c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125V6.375m16.5 0v3.75m-16.5-3.75v3.75m16.5 0v3.75C20.25 16.153 16.556 18 12 18s-8.25-1.847-8.25-4.125v-3.75m16.5 0c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125",
        "summary": "Infrastructure that's provisioned, secured, monitored, and backed up — without you touching a terminal.",
        "overview": (
            "We provision and manage the servers your sites, apps, and game servers actually run on — VPS, "
            "dedicated, or game hosting — including migration from wherever you are now, backups, monitoring, "
            "and day-to-day management so infrastructure isn't something you have to think about."
        ),
        "services": [
            "VPS hosting", "Dedicated servers", "Game servers", "Server provisioning",
            "Server migration", "Server management", "Backups", "Monitoring",
            "Performance optimisation",
        ],
        "tech_label": "Hosting Types",
        "tech": ["VPS", "Dedicated", "Game Servers"],
        "process": [
            ("Assess", "We review your current setup — or your requirements, if starting fresh."),
            ("Provision", "Server built, secured, and configured for your specific workload."),
            ("Migrate", "Existing sites, databases, and services moved across with a tested rollback plan."),
            ("Monitor", "Uptime, resource use, and security events tracked continuously."),
            ("Maintain", "Backups, updates, and performance tuning handled on an ongoing basis."),
        ],
        "packages": [
            ("VPS Hosting", "Shared-tenant virtual server for sites and small apps.", ["Managed OS & security updates", "Daily backups", "Monitoring included"]),
            ("Dedicated Server", "Full physical server for heavier workloads.", ["Dedicated resources", "Custom provisioning", "Priority support"]),
            ("Game Server Hosting", "FiveM and other game servers, tuned for player load.", ["Optimised for tickrate/uptime", "Panel or SSH access", "Migration support"]),
        ],
        "faqs": [
            ("Can you migrate my site without downtime?", "In most cases yes — we stage the migration and cut over DNS once everything's verified."),
            ("Do you manage the server, or just provide it?", "Both options exist — fully managed, or provisioned and handed to you."),
            ("What's included in monitoring?", "Uptime, resource thresholds, and security events, with alerts before small issues become outages."),
        ],
        "cta_label": "Explore Hosting",
    },

    "system-setup": {
        "order": 5,
        "eyebrow": "Division 05",
        "name": "System Setup",
        "short_name": "System Setup",
        "tagline": "OS installation, hardening, and configuration for Linux and Windows environments.",
        "accent": "#38bdf8",
        "icon": "M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25",
        "summary": "Clean installs, hardened configurations, and tuned performance — for Linux, Windows, and Windows Server.",
        "overview": (
            "We install, configure, and secure operating systems and server environments — from a clean Linux "
            "install to a hardened Windows Server deployment — with monitoring and performance tuning built "
            "in from the start rather than bolted on afterward."
        ),
        "services": [
            "Linux installation", "Windows installation", "Windows Server configuration",
            "Linux server configuration", "System hardening", "Monitoring",
            "Performance tuning", "Security configuration", "Software installation",
            "Server optimisation",
        ],
        "tech_label": "Technologies",
        "tech": ["Linux", "Windows", "Windows Server", "Hardening"],
        "process": [
            ("Plan", "We agree the OS, role, and security requirements before touching hardware."),
            ("Install", "Clean install or reimage, configured to your specification."),
            ("Harden", "Firewall rules, access control, and patching set up from day one."),
            ("Tune", "Performance tuned for the actual workload the system will run."),
            ("Handover", "Documentation and credentials handed over, or managed on your behalf."),
        ],
        "faqs": [
            ("Windows Server or Linux — which do I need?", "Depends on the workload; we'll recommend based on what you're actually running, not habit."),
            ("Can you harden an existing system?", "Yes — we'll audit the current configuration and close gaps without breaking what already works."),
            ("Do you handle ongoing patching?", "Yes, as part of System Setup or bundled with a Hosting management plan."),
        ],
        "cta_label": "Request System Setup",
    },

    "onsite-it-networking": {
        "order": 6,
        "eyebrow": "Division 06",
        "name": "On-Site IT & Networking",
        "short_name": "On-Site IT & Networking",
        "tagline": "Physical installs, cabling, and network setup — someone actually shows up.",
        "accent": "#ef4444",
        "icon": "M8.288 15.038a5.25 5.25 0 017.424 0M5.106 11.856c3.807-3.808 9.98-3.808 13.788 0M1.924 8.674c5.565-5.565 14.587-5.565 20.152 0M12.53 18.22l-.53.53-.53-.53a.75.75 0 011.06 0z",
        "summary": "Networking, cabling, and hardware installs handled in person, for businesses and homes alike.",
        "overview": (
            "Not everything can be fixed remotely. On-Site IT & Networking covers physical installs — cabling, "
            "Wi-Fi, network hardware, and general technical support — for businesses and homes where someone "
            "genuinely needs to turn up and do the work."
        ),
        "services": [
            "Network installation", "Wi-Fi installation", "Cabling", "Hardware installation",
            "Network configuration", "Router/switch configuration", "Business networking",
            "Equipment setup", "Troubleshooting", "On-site technical support",
        ],
        "tech_label": "Specialities",
        "tech": ["Networking", "Cabling", "Wi-Fi", "Hardware"],
        "process": [
            ("Enquire", "Tell us the site, the job, and roughly when you need it done."),
            ("Scope a visit", "We confirm scope, timing, and any access requirements ahead of time."),
            ("On-site work", "Cabling, hardware, and configuration carried out at your location."),
            ("Test", "Everything verified working before we leave — not just installed."),
            ("Follow-up", "Any issues after the visit go straight into a ticket, same as remote work."),
        ],
        "faqs": [
            ("What areas do you cover?", "Get in touch with your location and we'll confirm whether an on-site visit is available."),
            ("Business or home visits?", "Both — from full office network installs to a single home Wi-Fi setup."),
            ("Do I need to buy hardware first?", "No — we can spec and supply hardware as part of the visit, or work with what you already have."),
        ],
        "cta_label": "View On-Site Options",
    },
}

SERVICES_ORDERED = sorted(SERVICES.items(), key=lambda kv: kv[1]["order"])


def get_service(slug):
    return SERVICES.get(slug)
