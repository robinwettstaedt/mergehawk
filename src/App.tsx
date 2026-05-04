import { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type PullRequest = {
  id: string;
  title: string;
  number: number;
  url: string;
  repo: string;
  ciState: string;
  reviewDecision: string;
  commentCount: number;
  reviewCount: number;
  isMine: boolean;
  author: string;
  mergeable: string;
  draft: boolean;
};

type PrEvent = {
  type: string;
  prId: string;
};

type DashboardState = {
  pullRequests: PullRequest[];
  events: PrEvent[];
  syncedAt: string | null;
  source?: string;
  account?: {
    login: string;
    avatarUrl?: string;
  } | null;
  auth?: AuthState;
};

type AuthState = {
  configured: boolean;
  status: "signed_out" | "signing_in" | "signed_in";
  error?: string | null;
  account?: {
    login: string;
    avatarUrl?: string;
  } | null;
  flow?: {
    userCode: string;
    verificationUri: string;
    expiresAt: string;
  } | null;
};

declare global {
  interface Window {
    vcDash?: {
      getState: () => Promise<DashboardState>;
      refresh: () => Promise<DashboardState>;
      getAuthState: () => Promise<AuthState>;
      startSignIn: () => Promise<AuthState>;
      signOut: () => Promise<AuthState>;
      onState: (callback: (state: DashboardState) => void) => () => void;
    };
  }
}

const fallbackState: DashboardState = {
  pullRequests: [],
  events: [],
  syncedAt: null,
  account: null,
  auth: {
    configured: false,
    status: "signed_out"
  }
};

function App() {
  const [state, setState] = useState<DashboardState>(fallbackState);
  const [selectedView, setSelectedView] = useState("Needs Attention");
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [authError, setAuthError] = useState<string | null>(null);

  useEffect(() => {
    window.vcDash?.getState().then(setState);
    return window.vcDash?.onState(setState);
  }, []);

  const attentionIds = useMemo(() => new Set(state.events.map((event) => event.prId)), [state.events]);
  const visiblePullRequests = state.pullRequests.filter((pr) => {
    if (selectedView === "Needs Attention") return attentionIds.has(pr.id);
    if (selectedView === "My PRs") return pr.isMine;
    if (selectedView === "Review Requests") return !pr.isMine;
    return true;
  });

  async function refresh() {
    setIsRefreshing(true);
    try {
      const nextState = await window.vcDash?.refresh();
      if (nextState) setState(nextState);
    } finally {
      setIsRefreshing(false);
    }
  }

  async function startSignIn() {
    setAuthError(null);
    try {
      const auth = await window.vcDash?.startSignIn();
      if (auth) {
        setState((current) => ({ ...current, auth, account: auth.account ?? current.account }));
      }
    } catch (error) {
      setAuthError(error instanceof Error ? error.message : String(error));
    }
  }

  async function signOut() {
    const auth = await window.vcDash?.signOut();
    if (auth) {
      setState((current) => ({
        ...current,
        pullRequests: [],
        events: [],
        auth,
        account: null,
        source: "mock"
      }));
    }
  }

  return (
    <main className="shell">
      <aside className="sidebar">
        <div>
          <h1>VC Dash</h1>
          <p>{state.events.length} updates need attention</p>
        </div>
        <AuthPanel auth={state.auth} error={authError} onSignIn={startSignIn} onSignOut={signOut} />
        <nav>
          {["Needs Attention", "My PRs", "Review Requests", "Assigned", "Recent"].map((view) => (
            <button
              key={view}
              className={view === selectedView ? "active" : ""}
              onClick={() => setSelectedView(view)}
            >
              {view}
            </button>
          ))}
        </nav>
        <button className="refresh" onClick={refresh} disabled={isRefreshing}>
          {isRefreshing ? "Refreshing..." : "Refresh"}
        </button>
        <span className="sync-time">
          {state.syncedAt ? `Last sync ${new Date(state.syncedAt).toLocaleTimeString()}` : "Not synced yet"}
          {state.source ? ` · ${state.source}` : ""}
        </span>
      </aside>

      <section className="content">
        <header>
          <div>
            <span className="eyebrow">{selectedView}</span>
            <h2>Pull Requests</h2>
          </div>
          <button onClick={refresh} disabled={isRefreshing}>
            Refresh Now
          </button>
        </header>

        <div className="pr-list">
          {visiblePullRequests.length === 0 ? (
            <div className="empty">No PRs in this view.</div>
          ) : (
            visiblePullRequests.map((pr) => (
              <article key={pr.id} className={attentionIds.has(pr.id) ? "pr attention" : "pr"}>
                <div>
                  <span className="repo">{pr.repo}</span>
                  <h3>
                    <a href={pr.url}>{pr.title}</a>
                  </h3>
                  <p>
                    #{pr.number} by {pr.author}
                  </p>
                </div>
                <div className="badges">
                  <StatusBadge label={pr.ciState} kind={pr.ciState} />
                  <StatusBadge label={pr.reviewDecision.replace("_", " ")} kind={pr.reviewDecision} />
                  <StatusBadge label={pr.mergeable} kind={pr.mergeable} />
                  {attentionIds.has(pr.id) ? <StatusBadge label="new activity" kind="attention" /> : null}
                </div>
              </article>
            ))
          )}
        </div>
      </section>
    </main>
  );
}

function AuthPanel({
  auth,
  error,
  onSignIn,
  onSignOut
}: {
  auth?: AuthState;
  error: string | null;
  onSignIn: () => void;
  onSignOut: () => void;
}) {
  if (auth?.status === "signed_in") {
    return (
      <section className="auth-panel">
        <span className="eyebrow">GitHub</span>
        <strong>{auth.account?.login}</strong>
        <button onClick={onSignOut}>Sign Out</button>
      </section>
    );
  }

  if (auth?.status === "signing_in" && auth.flow) {
    return (
      <section className="auth-panel">
        <span className="eyebrow">GitHub Sign In</span>
        <strong className="user-code">{auth.flow.userCode}</strong>
        <a href={auth.flow.verificationUri}>{auth.flow.verificationUri}</a>
        <small>Expires {new Date(auth.flow.expiresAt).toLocaleTimeString()}</small>
      </section>
    );
  }

  return (
    <section className="auth-panel">
      <span className="eyebrow">GitHub</span>
      <button onClick={onSignIn}>Sign In</button>
      {!auth?.configured ? <small className="error">Set GITHUB_CLIENT_ID before signing in.</small> : null}
      {auth?.error ? <small className="error">{auth.error}</small> : null}
      {error ? <small className="error">{error}</small> : null}
    </section>
  );
}

function StatusBadge({ label, kind }: { label: string; kind: string }) {
  return <span className={`badge ${kind}`}>{label}</span>;
}

createRoot(document.getElementById("root")!).render(<App />);
