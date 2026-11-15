import Link from "next/link";

// Shown when someone opens an address that doesn't exist (GitHub Pages serves it as 404.html).
// Link goes through Next, so it also works when the site sits inside a sub-folder.
export default function NotFound() {
  return (
    <main className="notfound">
      <div className="card">
        <h1>Page not found</h1>
        <p className="msg">This address doesn&apos;t exist on LockedIn. Check the link, or go to the front page.</p>
        <Link className="btn primary" href="/">Go to LockedIn</Link>
      </div>
    </main>
  );
}
