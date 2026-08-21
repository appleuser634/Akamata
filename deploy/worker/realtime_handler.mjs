// Deploy this module as the service-binding target for realtime application
// handlers. Its public/default entrypoint is deliberately inert; Durable
// Objects can invoke only the named entrypoint through a Service Binding.
export { AkamataRealtimeApplication } from "./index.mjs";

export default {
  async fetch() {
    return Response.json({ error: "not_found" }, { status: 404 });
  },
};
