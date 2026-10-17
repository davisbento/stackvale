import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Stackvale — Every project has its place",
  description: "A calmer way to manage local development projects and services on macOS.",
  openGraph: {
    title: "Stackvale — Every project has its place",
    description: "A calmer way to manage local development projects and services on macOS.",
    type: "website"
  },
  twitter: {
    card: "summary_large_image",
    title: "Stackvale — Every project has its place",
    description: "A calmer way to manage local development projects and services on macOS."
  }
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
