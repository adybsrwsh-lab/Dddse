

## Sliplane deployment

This node uses the official PasarGuard gRPC/TLS API. It is not an HTTP web app.
Create the Sliplane service as a **public TCP service**, not `TCP/HTTP`:

1. Deploy this repository from GitHub and select the `Dockerfile`.
2. Enable **Expose service**.
3. Choose networking protocol **TCP**.
4. Do not configure an HTTP health-check route. HTTP health checks cannot validate this gRPC service.
5. Set the container port to `62050` (or set `SERVICE_PORT` to the port selected for the service).
6. Attach a persistent volume at `/var/lib/pg-node`.
7. Set these variables:

   ```text
   NODE_PUBLIC_HOST=<the Sliplane public hostname, without scheme or port>
   NODE_PUBLIC_PORT=<the public TCP port shown by Sliplane>
   SERVICE_PORT=62050
   SERVICE_PROTOCOL=grpc
   API_KEY=<a valid UUID>
   PRINT_CONNECTION_INFO=true
   ```

   If `NODE_PUBLIC_HOST` is omitted, the entrypoint uses `SLIPLANE_DOMAIN` when available. `NODE_PUBLIC_PORT` is the **external** port shown in Sliplane; `SERVICE_PORT` is the **internal container** port. They may be different.

8. After deployment, use the values printed in the log in the PasarGuard panel:

   ```text
   Address  = NODE_PUBLIC_HOST
   Port     = NODE_PUBLIC_PORT
   Protocol = grpc
   API Key  = API_KEY
   Certificate = complete PEM block from BEGIN CERTIFICATE to END CERTIFICATE
   ```

If the service shows `healthchecks on path '/' keep failing`, the service was created as `TCP/HTTP` or an HTTP health route was configured. Create a new service with **Deploy Copy** and select **TCP**; Sliplane does not allow changing the protocol on an existing service.

### Important platform limitation

A successful TCP/gRPC node deployment does not guarantee that PasarGuard data-plane features such as WireGuard, kernel routing, or user traffic forwarding are available on a managed platform. Test only on workloads allowed by Sliplane's Acceptable Use Policy. Do not use the service as an open proxy, VPN exit, or anonymization relay without explicit written permission from Sliplane.
