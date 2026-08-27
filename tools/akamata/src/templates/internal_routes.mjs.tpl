export const REALTIME_AUTHORIZE_PATH = "/__akamata/realtime/authorize";
export const REALTIME_MESSAGE_PATH = "/realtime/message";

export function isInternalRealtimePath(pathname) {
  return pathname === REALTIME_AUTHORIZE_PATH || pathname === REALTIME_MESSAGE_PATH;
}

export function rejectPublicInternalRoute(request) {
  return isInternalRealtimePath(new URL(request.url).pathname)
    ? Response.json({ error: "not_found" }, { status: 404 })
    : null;
}
