/** What `show()` resolves to. Every failure is `noFill`; the SDK never throws into your app. */
export type ShowResult = 'noFill' | 'dismissed' | 'completed';

/** Anonymous lifecycle event. Carries no survey titles, topics or answers. */
export type ConnectEvent = {
  type: 'shown' | 'started' | 'dismissed' | 'completed' | 'noFill' | 'notified';
  offerId?: string;
};

/**
 * Returns the signed user token from your server when someone is signed in.
 * Return `null` (or `undefined`) only when nobody is signed in: the SDK then offers guest studies, if your app allows guests.
 * Throw (or reject) when you cannot get a token, for example when your token endpoint fails: nothing is shown
 * (`noFill`) and the person is never treated as a guest. No answer within 10 seconds also counts as a failure.
 * Called on demand; the SDK does not keep the token longer than one check.
 */
export type TokenProvider = () => Promise<string | null | undefined> | string | null | undefined;

export type StartOptions = {
  /** Your publishable key, `pk_test_...` or `pk_live_...`. */
  key: string;
  /** Override the API base URL. Defaults to the FOUNTIS production API. */
  apiBase?: string;
  /** Web only: override the URL of the hosted survey engine. */
  engineUrl?: string;
};
