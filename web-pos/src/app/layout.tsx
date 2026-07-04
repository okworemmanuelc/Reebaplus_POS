import type { Metadata, Viewport } from 'next';

import './globals.css';
import { SessionProvider } from '@/components/providers/SessionProvider';
import { ThemeProvider } from '@/components/providers/ThemeProvider';
import { IdleLock } from '@/components/auth/IdleLock';

export const metadata: Metadata = {
  title: 'Reebaplus Web POS',
  description: 'Operate your business live from any computer.',
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  maximumScale: 1,
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        <SessionProvider>
          {/* Applies the business palette live at the document root. */}
          <ThemeProvider />
          {/* Re-locks the tab to sign-in after inactivity. */}
          <IdleLock />
          {children}
        </SessionProvider>
      </body>
    </html>
  );
}
