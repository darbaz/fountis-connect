import type { ConnectEvent, ShowResult, StartOptions, TokenProvider } from './types';
export type { ConnectEvent, ShowResult, StartOptions, TokenProvider } from './types';
/** Starts the SDK. Call once, early. Safe to call again. */
export declare function start(options: StartOptions): void;
/**
 * Gives the SDK a way to get the signed user token from your server. The function returns the token when someone is
 * signed in and `null` only when nobody is. Throw (or reject) when you cannot get a token, for example when your token
 * endpoint fails: nothing is shown then, and the person is not treated as a guest. No answer within 10 seconds also
 * counts as a failure.
 */
export declare function setUserToken(tokenProvider: TokenProvider | string | null): void;
/** Turns on the background check and asks for the notification permission. One notification a day at most. */
export declare function enableNotifications(): void;
/** Looks for a matching study and shows it full screen. Resolves when the person is done. */
export declare function show(): Promise<ShowResult>;
/** Call from your push handler with the message data. Resolves `true` if it was a FOUNTIS push (it has a `fountis` key). */
export declare function handlePush(data: Record<string, unknown>): Promise<boolean>;
/** Pass the person's consent to be offered studies. Default: true. */
export declare function setUserConsent(granted: boolean): void;
/** Forget the signed-in person: removes their local state and pending notifications. */
export declare function signOut(): void;
/** Listens to anonymous lifecycle events. Returns a function that removes the listener. */
export declare function onEvent(listener: (event: ConnectEvent) => void): () => void;
declare const FountisConnect: {
    start: typeof start;
    setUserToken: typeof setUserToken;
    enableNotifications: typeof enableNotifications;
    show: typeof show;
    handlePush: typeof handlePush;
    setUserConsent: typeof setUserConsent;
    signOut: typeof signOut;
    onEvent: typeof onEvent;
};
export default FountisConnect;
