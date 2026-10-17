import Image from "next/image";

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
        <div className="hero-copy"><p className="eyebrow">A calmer local workspace</p><h1>Every project<br /><em>has its place.</em></h1><p className="lede">Stackvale brings your projects and local services into one focused macOS app, so you can spend less time managing your setup and more time building.</p><a className="button" href="/Stackvale.dmg">Download for macOS <span>↗</span></a><p className="caption">Free while in early access · Apple Silicon & Intel</p></div>
        <div className="hero-art"><Image src="/stackvale-logo.png" alt="Stackvale mountain logo" width={640} height={640} priority /></div>
      </section>
      <section className="manifesto"><p className="eyebrow">Built for the way you work</p><h2>Your tools should feel<br /><em>like a place,</em> not a puzzle.</h2></section>
      <section className="features" id="features">{features.map(([title, text], index) => <article className="feature" key={title}><span>0{index + 1}</span><h3>{title}</h3><p>{text}</p></article>)}</section>
      <section className="closing"><Image src="/stackvale-icon.png" alt="Stackvale" width={64} height={64} /><h2>Make space for<br /><em>good work.</em></h2><a className="button" href="/Stackvale.dmg">Get Stackvale <span>↗</span></a></section>
      <footer><span>© 2026 Stackvale</span><span>Made for macOS</span></footer>
    </main>
  );
}
