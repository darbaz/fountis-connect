/**
 * @fountispanel/connect-react-native. Public API (same names as the native and web SDKs):
 *   start, setUserToken, enableNotifications, show, handlePush, setUserConsent, signOut, onEvent
 *
 * iOS and Android use the native FOUNTIS Connect SDKs (needs an Expo development build or a bare app, not Expo Go).
 * React Native Web wraps the Web SDK (see index.web.ts).
 */
import { requireNativeModule } from 'expo-modules-core';
let cached;
/** The native module, or null (with one console warning) when it is missing, for example in Expo Go. */
function native() {
    if (cached !== undefined)
        return cached;
    try {
        cached = requireNativeModule('FountisConnect');
    }
    catch {
        cached = null;
        console.warn('[FountisConnect] The native module was not found. Use an Expo development build or a bare React Native app (not Expo Go), and add the "@fountispanel/connect-react-native" config plugin.');
    }
    return cached;
}
let provider = null;
let tokenSub = null;
function ensureTokenListener(n) {
    if (tokenSub)
        return;
    // The native SDK asks for a token when it needs one. We answer from the function the app gave us.
    tokenSub = n.addListener('onTokenRequest', async (e) => {
        let token;
        try {
            token = (await provider?.()) ?? null;
        }
        catch {
            // A provider that throws could not get a token (a failed request, say). That is not "signed out", so never
            // answer null here: null makes the SDK offer guest studies to someone who is signed in. Report the failure instead.
            // An older native binary has no rejectToken: nothing is sent, the request times out as before and is read as null
            // (the old behaviour). Rebuild the native app to get the fix.
            if (typeof n.rejectToken === 'function')
                n.rejectToken(e.id);
            return;
        }
        n.resolveToken(e.id, token);
    });
}
/** Starts the SDK. Call once, early. Safe to call again. */
export function start(options) {
    try {
        native()?.start(options.key, options.apiBase ?? null);
    }
    catch { }
}
/**
 * Gives the SDK a way to get the signed user token from your server. The function returns the token when someone is
 * signed in and `null` only when nobody is. Throw (or reject) when you cannot get a token, for example when your token
 * endpoint fails: nothing is shown then, and the person is not treated as a guest. No answer within 10 seconds also
 * counts as a failure.
 */
export function setUserToken(tokenProvider) {
    try {
        provider = typeof tokenProvider === 'function' ? tokenProvider : () => tokenProvider;
        const n = native();
        if (!n)
            return;
        ensureTokenListener(n);
        n.setTokenProviderEnabled(true);
    }
    catch { }
}
/** Turns on the background check and asks for the notification permission. One notification a day at most. */
export function enableNotifications() {
    try {
        native()?.enableNotifications();
    }
    catch { }
}
/** Looks for a matching study and shows it full screen. Resolves when the person is done. */
export async function show() {
    try {
        return (await native()?.show()) ?? 'noFill';
    }
    catch {
        return 'noFill';
    }
}
/** Call from your push handler with the message data. Resolves `true` if it was a FOUNTIS push (it has a `fountis` key). */
export async function handlePush(data) {
    try {
        const strings = {};
        for (const [k, v] of Object.entries(data ?? {}))
            strings[k] = typeof v === 'string' ? v : String(v);
        return (await native()?.handlePush(strings)) ?? false;
    }
    catch {
        return false;
    }
}
/** Pass the person's consent to be offered studies. Default: true. */
export function setUserConsent(granted) {
    try {
        native()?.setUserConsent(granted);
    }
    catch { }
}
/** Forget the signed-in person: removes their local state and pending notifications. */
export function signOut() {
    try {
        native()?.signOut();
    }
    catch { }
}
/** Listens to anonymous lifecycle events. Returns a function that removes the listener. */
export function onEvent(listener) {
    const n = native();
    if (!n)
        return () => { };
    const sub = n.addListener('onFountisEvent', (e) => {
        try {
            listener(e);
        }
        catch { }
    });
    return () => sub.remove();
}
const FountisConnect = { start, setUserToken, enableNotifications, show, handlePush, setUserConsent, signOut, onEvent };
export default FountisConnect;
