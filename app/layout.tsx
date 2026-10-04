import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "简账 · 让每一笔都清晰",
  description: "个人收支、账户、分类、预算与统计，简单记录，清晰生活。",
  manifest: "/manifest.webmanifest",
  other: {
    "codex-preview": "development",
  },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body className="antialiased">{children}</body>
    </html>
  );
}
