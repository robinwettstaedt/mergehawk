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
};

declare global {
  interface Window {
    vcDash?: {
      getState: () => Promise<DashboardState>;
      refresh: () => Promise<DashboardState>;
      onState: (callback: (state: DashboardState) => void) => () => void;
    };
  }
}

const fallbackState: DashboardState = {
  pullRequests: [],
  events: [],
  syncedAt: null
};

function App() {
  const [state, setState] = useState<DashboardState>(fallbackState);
  const [selectedView, setSelectedView] = useState("Needs Attention");
  const [isRefreshing, setIsRefreshing] = useState(false);

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

  return (
    <main className="shell">
      <aside className="sidebar">
        <div>
          <h1>VC Dash</h1>
          <p>{state.events.length} updates need attention</p>
        </div>
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

function StatusBadge({ label, kind }: { label: string; kind: string }) {
  return <span className={`badge ${kind}`}>{label}</span>;
}

createRoot(document.getElementById("root")!).render(<App />);
