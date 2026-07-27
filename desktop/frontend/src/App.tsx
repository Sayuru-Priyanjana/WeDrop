import { useState, useEffect } from 'react';
import { 
  GetDevices, GetTrustedDevices, RequestPairing, AcceptPairing, RejectPairing, 
  RemoveTrustedDevice, GetSettings, SetAutoSyncClipboard, SelectFile, SendFile 
} from '../wailsjs/go/main/WeDropService';
import { protocol, storage } from '../wailsjs/go/models';
import { EventsOn } from '../wailsjs/runtime/runtime';

function App() {
  const [devices, setDevices] = useState<protocol.DiscoveryMessage[]>([]);
  const [trustedDevices, setTrustedDevices] = useState<storage.TrustedDevice[]>([]);
  const [settings, setSettings] = useState<storage.DeviceConfig | null>(null);
  
  const [activeTab, setActiveTab] = useState<'devices' | 'transfers' | 'settings'>('devices');
  const [pairingRequest, setPairingRequest] = useState<protocol.PairingReq | null>(null);

  useEffect(() => {
    GetSettings().then(setSettings);

    const interval = setInterval(() => {
      GetDevices().then(result => {
        if (result) setDevices(result);
      });
      GetTrustedDevices().then(result => {
        if (result) setTrustedDevices(result);
      });
    }, 2000);

    const unsubPairing = EventsOn("pairing_request", (req: protocol.PairingReq) => {
      setPairingRequest(req);
    });

    return () => {
      clearInterval(interval);
      unsubPairing();
    };
  }, []);

  const handleSendFile = async (deviceId: string) => {
    try {
      const filePath = await SelectFile();
      if (!filePath) return;
      setActiveTab('transfers');
      await SendFile(deviceId, filePath);
      alert('Transfer complete!');
    } catch (err) {
      alert('Transfer failed: ' + err);
    }
  };

  const handleRequestPairing = async (deviceId: string) => {
    try {
      await RequestPairing(deviceId);
      alert('Pairing accepted! Device added to Ecosystem.');
    } catch (err) {
      alert('Pairing failed or rejected by peer.');
    }
  };

  const untrustedDevices = devices.filter(
    d => !trustedDevices.some(td => td.device_id === d.device_id) && d.device_id !== settings?.device_id
  );

  return (
    <div className="h-screen w-screen flex bg-background text-text overflow-hidden font-sans">
      {/* Sidebar */}
      <div className="w-64 bg-surface/80 backdrop-blur-md border-r border-white/5 flex flex-col p-6 shadow-2xl relative z-20">
        <div className="flex items-center gap-3 mb-12">
          <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-primary to-secondary flex items-center justify-center shadow-lg shadow-primary/20">
            <svg className="w-6 h-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8" /></svg>
          </div>
          <h1 className="text-2xl font-bold bg-clip-text text-transparent bg-gradient-to-r from-white to-white/70">WeDrop</h1>
        </div>

        <nav className="flex flex-col gap-2">
          <button onClick={() => setActiveTab('devices')} className={`flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-300 ${activeTab === 'devices' ? 'bg-primary/10 text-primary font-medium shadow-sm' : 'text-textMuted hover:bg-white/5 hover:text-white'}`}>
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z" /></svg>
            Ecosystem
          </button>
          <button onClick={() => setActiveTab('transfers')} className={`flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-300 ${activeTab === 'transfers' ? 'bg-primary/10 text-primary font-medium shadow-sm' : 'text-textMuted hover:bg-white/5 hover:text-white'}`}>
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4" /></svg>
            Transfers
          </button>
          <button onClick={() => setActiveTab('settings')} className={`flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-300 ${activeTab === 'settings' ? 'bg-primary/10 text-primary font-medium shadow-sm' : 'text-textMuted hover:bg-white/5 hover:text-white'}`}>
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" /><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" /></svg>
            Settings
          </button>
        </nav>
      </div>

      {/* Main Content */}
      <div className="flex-1 flex flex-col p-10 relative z-0 overflow-y-auto">
        <div className="absolute top-0 right-0 w-[500px] h-[500px] bg-primary/20 rounded-full blur-[120px] -z-10 pointer-events-none translate-x-1/3 -translate-y-1/3"></div>
        
        {activeTab === 'devices' && (
          <div className="animate-in fade-in slide-in-from-bottom-4 duration-500">
            <h2 className="text-3xl font-light mb-8">My <span className="font-semibold text-white">Ecosystem</span></h2>
            
            {/* Ecosystem Devices */}
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 mb-12">
              {trustedDevices.length === 0 ? (
                <div className="col-span-full p-8 border border-dashed border-white/10 rounded-3xl bg-surface/30">
                  <p className="text-textMuted font-medium text-center">No paired devices. Discover devices on the radar below to add them.</p>
                </div>
              ) : (
                trustedDevices.map(device => {
                  const isOnline = devices.some(d => d.device_id === device.device_id);
                  return (
                  <div key={device.device_id} className="group relative bg-surface border border-primary/20 shadow-lg shadow-primary/5 rounded-3xl p-6 transition-all duration-300">
                    <div className="absolute top-4 right-4 flex gap-2">
                      <button onClick={() => handleSendFile(device.device_id)} className="w-8 h-8 rounded-full bg-primary/20 flex items-center justify-center hover:bg-primary/40 transition">
                        <svg className="w-4 h-4 text-primary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" /></svg>
                      </button>
                      <button onClick={() => RemoveTrustedDevice(device.device_id)} className="w-8 h-8 rounded-full bg-red-500/10 flex items-center justify-center hover:bg-red-500/30 transition">
                        <svg className="w-4 h-4 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" /></svg>
                      </button>
                    </div>
                    <div className="w-14 h-14 rounded-2xl bg-gradient-to-br from-primary/30 to-secondary/10 border border-primary/20 flex items-center justify-center mb-6">
                      <svg className="w-7 h-7 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z" /></svg>
                    </div>
                    <h3 className="text-xl font-semibold mb-1">{device.name}</h3>
                    <div className="flex items-center gap-2">
                      <span className={`w-2 h-2 rounded-full ${isOnline ? 'bg-green-500 shadow-[0_0_8px_rgba(34,197,94,0.6)]' : 'bg-gray-500'}`}></span>
                      <p className="text-sm text-textMuted">{isOnline ? 'Online & Synced' : 'Offline'}</p>
                    </div>
                  </div>
                )})
              )}
            </div>

            {/* Radar */}
            <h2 className="text-2xl font-light mb-6">Nearby <span className="font-semibold text-white">Radar</span></h2>
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
              {untrustedDevices.length === 0 ? (
                <div className="col-span-full flex flex-col items-center justify-center p-12 border border-dashed border-white/10 rounded-3xl bg-surface/30">
                  <p className="text-textMuted font-medium text-center">Scanning for untrusted devices...</p>
                </div>
              ) : (
                untrustedDevices.map(device => (
                  <div key={device.device_id} className="group relative bg-surface border border-white/5 rounded-3xl p-6 transition-all duration-300">
                    <button onClick={() => handleRequestPairing(device.device_id)} className="absolute top-4 right-4 text-xs font-medium bg-primary text-white px-3 py-1.5 rounded-full shadow-lg shadow-primary/30 hover:bg-primary/90 transition">
                      Add to Ecosystem
                    </button>
                    <div className="w-14 h-14 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center mb-6">
                      <svg className="w-7 h-7 text-white/50" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 18h.01M8 21h8a2 2 0 002-2V5a2 2 0 00-2-2H8a2 2 0 00-2 2v14a2 2 0 002 2z" /></svg>
                    </div>
                    <h3 className="text-xl font-semibold mb-1">{device.name}</h3>
                    <div className="flex items-center gap-2">
                      <p className="text-sm text-textMuted">{device.platform} • Untrusted</p>
                    </div>
                  </div>
                ))
              )}
            </div>
          </div>
        )}

        {activeTab === 'settings' && settings && (
          <div className="animate-in fade-in slide-in-from-bottom-4 duration-500 max-w-2xl">
            <h2 className="text-3xl font-light mb-8">System <span className="font-semibold text-white">Settings</span></h2>
            
            <div className="bg-surface border border-white/5 rounded-3xl p-8 mb-6">
              <div className="flex items-center justify-between mb-2">
                <div>
                  <h3 className="text-xl font-medium">Auto Sync Clipboard</h3>
                  <p className="text-textMuted text-sm mt-1">Automatically copy clipboard contents across all trusted Ecosystem devices.</p>
                </div>
                <button 
                  onClick={() => {
                    const newVal = !settings.auto_sync_clipboard;
                    SetAutoSyncClipboard(newVal);
                    setSettings({...settings, auto_sync_clipboard: newVal});
                  }}
                  className={`w-14 h-8 rounded-full transition-colors relative ${settings.auto_sync_clipboard ? 'bg-primary' : 'bg-white/10'}`}
                >
                  <div className={`w-6 h-6 rounded-full bg-white absolute top-1 transition-all ${settings.auto_sync_clipboard ? 'left-7' : 'left-1'}`}></div>
                </button>
              </div>
            </div>
            
            <div className="bg-surface border border-white/5 rounded-3xl p-8">
              <h3 className="text-xl font-medium mb-4">Device Identity</h3>
              <div className="space-y-4">
                <div>
                  <p className="text-sm text-textMuted mb-1">Device Name</p>
                  <p className="font-mono bg-black/20 p-3 rounded-lg border border-white/5">{settings.name}</p>
                </div>
                <div>
                  <p className="text-sm text-textMuted mb-1">Public Key (Identity)</p>
                  <p className="font-mono text-xs break-all bg-black/20 p-3 rounded-lg border border-white/5">{settings.public_key}</p>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Pairing Modal */}
      {pairingRequest && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm animate-in fade-in">
          <div className="bg-surface border border-primary/30 shadow-2xl rounded-3xl p-8 max-w-sm w-full mx-4 text-center">
            <div className="w-16 h-16 rounded-full bg-primary/20 flex items-center justify-center mx-auto mb-6">
              <svg className="w-8 h-8 text-primary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 11c0 3.517-1.009 6.799-2.753 9.571m-3.44-2.04l.054-.09A13.916 13.916 0 008 11a4 4 0 118 0c0 1.017-.07 2.019-.203 3m-2.118 6.844A21.88 21.88 0 0015.171 17m3.839 1.132c.645-2.266.99-4.659.99-7.132A8 8 0 008 4.07M3 15.364c.64-1.319 1-2.8 1-4.364 0-1.457.39-2.823 1.07-4" /></svg>
            </div>
            <h3 className="text-2xl font-semibold mb-2">Pairing Request</h3>
            <p className="text-textMuted mb-8">
              <strong className="text-white">{pairingRequest.name}</strong> wants to join your Ecosystem. Do you trust this device?
            </p>
            <div className="flex gap-4">
              <button 
                onClick={() => { RejectPairing(pairingRequest.device_id); setPairingRequest(null); }}
                className="flex-1 py-3 rounded-xl bg-white/5 hover:bg-white/10 transition font-medium"
              >
                Reject
              </button>
              <button 
                onClick={() => { AcceptPairing(pairingRequest.device_id); setPairingRequest(null); }}
                className="flex-1 py-3 rounded-xl bg-primary hover:bg-primary/90 text-white transition font-medium shadow-lg shadow-primary/20"
              >
                Accept
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

export default App
