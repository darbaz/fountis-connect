import type { ConnectEvent, ShowResult, StartOptions, TokenProvider } from './types';
export type { ConnectEvent, ShowResult, StartOptions, TokenProvider } from './types';
export declare function start(options: StartOptions): void;
export declare function setUserToken(tokenProvider: TokenProvider | string | null): void;
export declare function enableNotifications(): void;
export declare function show(): Promise<ShowResult>;
/** The web has no push messages. */
export declare function handlePush(_data: Record<string, unknown>): Promise<boolean>;
export declare function setUserConsent(granted: boolean): void;
export declare function signOut(): void;
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
