import Image from "next/image";

const downloadUrl = "https://github.com/davisbento/stackvale/releases/latest/download/Stackvale.dmg";

const features = [
  ["One home for every project", "Keep repositories, services, and their context together instead of scattered across terminals."],
  ["See what is running", "Understand the real state of local services at a glance, from a quiet menu bar popover."],
  ["Start with intention", "Discover commands automatically, then choose exactly what to run. No surprises when switching projects."]
];

export default function Home() {
  return (
    <main>
      <nav className="nav"><a className="brand" href="#top"><Image src="/stackvale-icon.png" alt="" width={36} height={36} /> <span>stackvale</span></a><a className="nav-link" href="#features">How it works</a></nav>
      <section className="hero" id="top">
        <div className="hero-copy"><p className="eyebrow">A calmer local workspace</p><h1>Every project<br /><em>has its place.</em></h1><p className="lede">Stackvale brings your projects and local services into one focused macOS app, so you can spend less time managing your setup and more time building.</p><a className="button" href={downloadUrl}>Download for macOS <span>↗</span></a><p className="caption">Free while in early access · Apple Silicon & Intel</p></div>
        <div className="hero-art"><Image src="/stackvale-app-preview.png" alt="Stackvale menu bar popover showing a project and its local services" width={1133} height={1388} priority /><p className="image-label">Menu bar popover</p></div>
      </section>
      <section className="app-tour" aria-labelledby="app-tour-title">
        <div className="app-tour-heading"><p className="eyebrow">The full app</p><h2 id="app-tour-title">A bigger view,<br /><em>when you need it.</em></h2><p>Open Stackvale to see every local service together, then focus on the details behind any one of them.</p></div>
        <div className="app-screenshots">
          <figure><Image src="/stackvale-app-overview.png" alt="Stackvale application overview with local services grouped by project" width={1594} height={986} /><figcaption>Application overview · every service in one place</figcaption></figure>
          <figure><Image src="/stackvale-service-detail.png" alt="Stackvale service detail view with command, directory, logs, and terminal" width={1584} height={993} /><figcaption>Service detail · commands, logs, and terminal context</figcaption></figure>
        </div>
      </section>
      <section className="manifesto"><p className="eyebrow">Built for the way you work</p><h2>Your tools should feel<br /><em>like a place,</em> not a puzzle.</h2></section>
      <section className="features" id="features">{features.map(([title, text], index) => <article className="feature" key={title}><span>0{index + 1}</span><h3>{title}</h3><p>{text}</p></article>)}</section>
      <section className="closing"><Image src="/stackvale-icon.png" alt="Stackvale" width={64} height={64} /><h2>Make space for<br /><em>good work.</em></h2><a className="button" href={downloadUrl}>Get Stackvale <span>↗</span></a></section>
      <footer><span>© 2026 Stackvale</span><span>Made for macOS</span></footer>
    </main>
  );
}
