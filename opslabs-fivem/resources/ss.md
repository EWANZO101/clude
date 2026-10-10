## Automatic Framework Detection & Universal Framework Integration

Change OPSLabs Phone to use an automatic framework detection system instead of requiring server owners to manually select their framework.

### Supported Frameworks

* ESX Legacy
* QBCore
* Qbox / QBX
* ox_core
* ND Core
* vRP
* Standalone servers
* Custom and privately developed frameworks

### Required Features

* Automatically detect the framework running on the server.
* Automatically load the correct framework integration.
* Detect Qbox before QBCore to avoid compatibility conflicts.
* Validate that the detected framework is running correctly.
* Display the detected framework and integration status in the server console.
* Allow manual framework selection as an optional override.
* Provide automatic fallback to standalone mode when no supported framework is detected.
* Display clear warnings when a framework is detected but not supported.
* Prevent the phone from crashing if a framework is missing or fails to initialise.

### Universal Custom Framework Integration

* Create a universal framework bridge that allows OPSLabs Phone to work with frameworks that are not natively supported.
* Provide a custom framework adapter template for developers.
* Allow custom adapters to connect player data, identifiers, jobs, money, notifications and permissions.
* Allow developers to register their own framework integrations without editing the phone's core files.
* Keep framework-specific code separate from the phone's apps and main systems.
* Include documentation and examples for creating new framework adapters.

### Additional Resource Integrations

* Automatically detect supported inventory systems.
* Support configurable phone items and item metadata.
* Provide separate integration adapters for banking, billing, garages, housing and voice systems.
* Allow server owners to configure integrations with third-party resources.
* Provide clear warnings when an optional dependency is missing.
* Ensure all integrations validate important actions server-side.

### Important Requirements

* Preserve all existing OPSLabs Phone features and ESX Legacy compatibility.
* Do not require server owners to edit source code to change frameworks.
* Make automatic detection the default behaviour.
* Ensure each framework adapter is tested before it is marked as officially supported.
* Allow future frameworks to be added without rewriting the entire phone system.
