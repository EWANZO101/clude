import { useState, useEffect } from 'react';
import { isDebug, useNuiEvent, fetchNui } from './hooks/useNui';

interface AdData {
  title: string;
  category: string;
  message: string;
  imageUrl?: string;
  duration?: number;
  type?: 'default' | 'business' | 'gang' | 'lifeinvader';
}

const EXIT_MS = 280;

const THEMES = {
  default: { accent: '79, 140, 255', accent2: '139, 92, 246', label: 'Sponsored' },
  gang:    { accent: '255, 59, 59', accent2: '255, 138, 59', label: 'Street Word' },
  lifeinvader: { accent: '236, 72, 120', accent2: '255, 120, 90', label: 'Lifeinvader' },
};

export default function App() {
  const [visible, setVisible] = useState(isDebug);
  const [closing, setClosing] = useState(false);
  const [adKey, setAdKey] = useState(0);
  const [ad, setAd] = useState<AdData>({
    title: 'Premium Vehicle Sale',
    category: 'VEHICLES',
    message: 'Get 20% off on all sports cars this week at Downtown Motors!',
    duration: 8000,
    type: 'default',
  });

  useNuiEvent<AdData>('showAd', (data) => {
    setAd(data);
    setClosing(false);
    setAdKey((k) => k + 1);
    setVisible(true);
  });

  useNuiEvent('hideAd', () => setClosing(true));

  // Expire after the ad duration
  useEffect(() => {
    if (!visible || closing) return;
    const t = setTimeout(() => setClosing(true), ad.duration || 8000);
    return () => clearTimeout(t);
  }, [visible, closing, adKey, ad.duration]);

  // Play exit animation, then unmount and tell the client
  useEffect(() => {
    if (!closing) return;
    const t = setTimeout(() => {
      setVisible(false);
      setClosing(false);
      fetchNui('adExpired', {}, { success: true });
    }, EXIT_MS);
    return () => clearTimeout(t);
  }, [closing]);

  if (!visible) return null;

  const theme = ad.type === 'gang' ? THEMES.gang : ad.type === 'lifeinvader' ? THEMES.lifeinvader : THEMES.default;
  const duration = ad.duration || 8000;

  return (
    <div className="fixed top-6 left-1/2 -translate-x-1/2 z-50">
      <div
        key={adKey}
        className={`ad-card relative w-[440px] rounded-[22px] overflow-hidden ${closing ? 'ad-exit' : 'ad-enter'}`}
        style={{ ['--accent-rgb' as any]: theme.accent, ['--accent2-rgb' as any]: theme.accent2 }}
      >
        {/* Accent glow */}
        <div className="ad-glow pointer-events-none absolute -top-16 -left-10 w-48 h-48 rounded-full" />

        <div className="relative flex items-center gap-4 p-4 pr-5">
          {/* Image */}
          <div className="ad-thumb relative flex-shrink-0 w-[68px] h-[68px] rounded-2xl overflow-hidden">
            {ad.imageUrl ? (
              <img src={ad.imageUrl} alt="" className="w-full h-full object-cover" />
            ) : (
              <div className="w-full h-full flex items-center justify-center text-white/40">
                <svg className="w-7 h-7" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.6}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M10.34 15.84c-.69-.03-1.38-.04-2.09-.04H7.5a4.5 4.5 0 110-9h.75c.7 0 1.4-.02 2.09-.05m0 9.09c.25.97.59 1.9 1 2.8.26.57.06 1.25-.48 1.56l-.66.38c-.55.32-1.26.11-1.53-.46a17.9 17.9 0 01-1.44-4.28m3.11.99c-.39-1.5-.59-3.07-.59-4.69s.2-3.19.59-4.69m0 9.38a48.1 48.1 0 018.62 2.86c.33.14.7-.08.7-.44V3.75c0-.36-.37-.58-.7-.44a48.1 48.1 0 01-8.62 2.86" />
                </svg>
              </div>
            )}
          </div>

          {/* Text */}
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <span className="ad-dot w-1.5 h-1.5 rounded-full" />
              <span className="text-[10px] font-semibold uppercase tracking-[0.16em] text-white/50">
                {theme.label}
              </span>
              <span className="text-white/20 text-[10px]">•</span>
              <span className="ad-chip text-[10px] font-semibold uppercase tracking-[0.12em] px-2 py-[2px] rounded-full">
                {ad.category}
              </span>
            </div>
            <h2 className="text-white text-[17px] font-semibold leading-tight truncate">{ad.title}</h2>
            {ad.message && (
              <p className="text-white/65 text-[13px] leading-snug mt-1 line-clamp-2">{ad.message}</p>
            )}
          </div>
        </div>

        {/* Timer line */}
        <div className="relative h-[3px] bg-white/[0.06]">
          <div className="ad-progress h-full" style={{ animationDuration: `${duration}ms` }} />
        </div>
      </div>
    </div>
  );
}
