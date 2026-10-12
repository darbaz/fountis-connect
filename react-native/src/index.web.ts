/**
 * React Native Web: wraps the Web SDK (`@fountispanel/connect`). Same API as the native build.
 * Notifications are an in-page invitation only, and there are no push messages on the web.
 */
import * as web from '@fountispanel/connect';
import type { ConnectEvent, ShowResult, StartOptions, TokenProvider } from './types';

export type { ConnectEvent, ShowResult, StartOptions, TokenProvider } from './types';

export function start(options: StartOptions): void {
  try {
    web.start({ key: options.key, apiBase: options.apiBase, engineUrl: options.engineUrl });
  } catch {}
}

export function setUserToken(tokenProvider: TokenProvider | string | null): void {
  try {
    web.setUserToken(
      typeof tokenProvider === 'function' ? async () => (await tokenProvider()) ?? null : (tokenProvider ?? null),
    );
  } catch {}
}

export function enableNotifications(): void {
  try {
    web.enableNotifications();
  } catch {}
}

export async function show(): Promise<ShowResult> {
  try {
    return await web.show();
  } catch {
    return 'noFill';
  }
}

/** The web has no push messages. */
export async function handlePush(_data: Record<string, unknown>): Promise<boolean> {
  return false;
}

export function setUserConsent(granted: boolean): void {
  try {
    web.setUserConsent(granted);
  } catch {}
}

export function signOut(): void {
  try {
    web.signOut();
  } catch {}
}

export function onEvent(listener: (event: ConnectEvent) => void): () => void {
  try {
    return web.onEvent((e) => listener(e as ConnectEvent));
  } catch {
    return () => {};
  }
}

const FountisConnect = { start, setUserToken, enableNotifications, show, handlePush, setUserConsent, signOut, onEvent };
export default FountisConnect;
