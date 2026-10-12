/**
 * React Native Web: wraps the Web SDK (`@fountispanel/connect`). Same API as the native build.
 * Notifications are an in-page invitation only, and there are no push messages on the web.
 */
import * as web from '@fountispanel/connect';
export function start(options) {
    try {
        web.start({ key: options.key, apiBase: options.apiBase, engineUrl: options.engineUrl });
    }
    catch { }
}
export function setUserToken(tokenProvider) {
    try {
        web.setUserToken(typeof tokenProvider === 'function' ? async () => (await tokenProvider()) ?? null : (tokenProvider ?? null));
    }
    catch { }
}
export function enableNotifications() {
    try {
        web.enableNotifications();
    }
    catch { }
}
export async function show() {
    try {
        return await web.show();
    }
    catch {
        return 'noFill';
    }
}
/** The web has no push messages. */
export async function handlePush(_data) {
    return false;
}
export function setUserConsent(granted) {
    try {
        web.setUserConsent(granted);
    }
    catch { }
}
export function signOut() {
    try {
        web.signOut();
    }
    catch { }
}
export function onEvent(listener) {
    try {
        return web.onEvent((e) => listener(e));
    }
    catch {
        return () => { };
    }
}
const FountisConnect = { start, setUserToken, enableNotifications, show, handlePush, setUserConsent, signOut, onEvent };
export default FountisConnect;
