---
name: byway-control
description: Manage Byway on a specific device through its authenticated API. Use for Byway proxy status, node and subscription management, connectivity tests, outlet selection, configuration, traffic, import, and sharing.
---

# Byway control

Use the device address and bearer token from Byway's AI connection instructions or the host's saved connection credentials. A host may provide them as `BYWAY_API_URL` (the API root URL) and `BYWAY_API_TOKEN`. Keep live credentials separate from this skill. If credentials are missing, use the new connection instructions copied from the user's Byway app.

1. Retrieve `GET /v1/guide` for the device's current commands and input fields. Make authenticated HTTP requests directly to the device, bypassing any system HTTP proxy on that path.
2. Read `GET /v1/status` to confirm the target by `deviceInfo.id` and read its current proxy state. `GET /v1/device` reads the same device identity, and `PATCH /v1/device` changes its `displayName`. Use the IDs returned by `GET /v1/nodes` or `GET /v1/groups` to resolve the object the user named.
3. Perform the requested operation and read the resulting device state. For Windows, check the active configuration and active node ID. Use the connection list to verify the rule and actual exit of a specific connection. If the candidate fails, check the current settings before retrying.

Use the saved skill on later requests and fetch the live guide for command details. Keep tokens, subscription URLs, node sharing links, and QR contents out of logs and unrelated replies.
