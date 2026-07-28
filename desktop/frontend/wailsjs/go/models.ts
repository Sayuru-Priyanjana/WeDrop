export namespace adaptivecontrols {
	
	export class AppAction {
	    id: string;
	    label: string;
	    icon: string;
	    color_value: number;
	    predefined: boolean;
	    action: protocol.WorkspaceAction;
	
	    static createFrom(source: any = {}) {
	        return new AppAction(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.label = source["label"];
	        this.icon = source["icon"];
	        this.color_value = source["color_value"];
	        this.predefined = source["predefined"];
	        this.action = this.convertValues(source["action"], protocol.WorkspaceAction);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class AppProfile {
	    exe: string;
	    display_name: string;
	    actions: AppAction[];
	
	    static createFrom(source: any = {}) {
	        return new AppProfile(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.exe = source["exe"];
	        this.display_name = source["display_name"];
	        this.actions = this.convertValues(source["actions"], AppAction);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace main {
	
	export class PairingPrompt {
	    device_id: string;
	    name: string;
	    platform: string;
	    form_factor: string;
	    verification_code: string;
	    address: string;
	    expires_at: number;
	
	    static createFrom(source: any = {}) {
	        return new PairingPrompt(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.device_id = source["device_id"];
	        this.name = source["name"];
	        this.platform = source["platform"];
	        this.form_factor = source["form_factor"];
	        this.verification_code = source["verification_code"];
	        this.address = source["address"];
	        this.expires_at = source["expires_at"];
	    }
	}
	export class NotificationView {
	    id: string;
	    device_id: string;
	    device_name: string;
	    app: string;
	    title: string;
	    body: string;
	    time: number;
	    read: boolean;
	
	    static createFrom(source: any = {}) {
	        return new NotificationView(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.device_id = source["device_id"];
	        this.device_name = source["device_name"];
	        this.app = source["app"];
	        this.title = source["title"];
	        this.body = source["body"];
	        this.time = source["time"];
	        this.read = source["read"];
	    }
	}
	export class ClipboardEntry {
	    text: string;
	    origin: string;
	    origin_name: string;
	    time: number;
	    incoming: boolean;
	
	    static createFrom(source: any = {}) {
	        return new ClipboardEntry(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.text = source["text"];
	        this.origin = source["origin"];
	        this.origin_name = source["origin_name"];
	        this.time = source["time"];
	        this.incoming = source["incoming"];
	    }
	}
	export class TransferView {
	    id: string;
	    device_id: string;
	    device_name: string;
	    filename: string;
	    size: number;
	    transferred: number;
	    incoming: boolean;
	    state: string;
	    error?: string;
	    saved_path?: string;
	    started_at: number;
	    updated_at: number;
	
	    static createFrom(source: any = {}) {
	        return new TransferView(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.device_id = source["device_id"];
	        this.device_name = source["device_name"];
	        this.filename = source["filename"];
	        this.size = source["size"];
	        this.transferred = source["transferred"];
	        this.incoming = source["incoming"];
	        this.state = source["state"];
	        this.error = source["error"];
	        this.saved_path = source["saved_path"];
	        this.started_at = source["started_at"];
	        this.updated_at = source["updated_at"];
	    }
	}
	export class DeviceView {
	    device_id: string;
	    name: string;
	    platform: string;
	    form_factor: string;
	    ip: string;
	    paired: boolean;
	    online: boolean;
	    connected: boolean;
	    battery: number;
	    allow_clipboard: boolean;
	    allow_files: boolean;
	    allow_notifications: boolean;
	    allow_media: boolean;
	    allow_workspace: boolean;
	    paired_at: number;
	    last_seen: number;
	    health?: protocol.DeviceHealth;
	    media?: protocol.MediaState;
	
	    static createFrom(source: any = {}) {
	        return new DeviceView(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.device_id = source["device_id"];
	        this.name = source["name"];
	        this.platform = source["platform"];
	        this.form_factor = source["form_factor"];
	        this.ip = source["ip"];
	        this.paired = source["paired"];
	        this.online = source["online"];
	        this.connected = source["connected"];
	        this.battery = source["battery"];
	        this.allow_clipboard = source["allow_clipboard"];
	        this.allow_files = source["allow_files"];
	        this.allow_notifications = source["allow_notifications"];
	        this.allow_media = source["allow_media"];
	        this.allow_workspace = source["allow_workspace"];
	        this.paired_at = source["paired_at"];
	        this.last_seen = source["last_seen"];
	        this.health = this.convertValues(source["health"], protocol.DeviceHealth);
	        this.media = this.convertValues(source["media"], protocol.MediaState);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	export class AppState {
	    ready: boolean;
	    error?: string;
	    self: DeviceView;
	    public_key: string;
	    settings: storage.Settings;
	    paired: DeviceView[];
	    discovered: DeviceView[];
	    transfers: TransferView[];
	    clipboard: ClipboardEntry[];
	    notifications: NotificationView[];
	    pairing?: PairingPrompt;
	    listen_port: number;
	
	    static createFrom(source: any = {}) {
	        return new AppState(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.ready = source["ready"];
	        this.error = source["error"];
	        this.self = this.convertValues(source["self"], DeviceView);
	        this.public_key = source["public_key"];
	        this.settings = this.convertValues(source["settings"], storage.Settings);
	        this.paired = this.convertValues(source["paired"], DeviceView);
	        this.discovered = this.convertValues(source["discovered"], DeviceView);
	        this.transfers = this.convertValues(source["transfers"], TransferView);
	        this.clipboard = this.convertValues(source["clipboard"], ClipboardEntry);
	        this.notifications = this.convertValues(source["notifications"], NotificationView);
	        this.pairing = this.convertValues(source["pairing"], PairingPrompt);
	        this.listen_port = source["listen_port"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	
	
	export class Diagnostics {
	    device_id: string;
	    listen_port: number;
	    discoverable: boolean;
	    peers_seen: number;
	    paired: number;
	    connected: string[];
	    data_dir: string;
	    download_dir: string;
	    fingerprint: string;
	
	    static createFrom(source: any = {}) {
	        return new Diagnostics(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.device_id = source["device_id"];
	        this.listen_port = source["listen_port"];
	        this.discoverable = source["discoverable"];
	        this.peers_seen = source["peers_seen"];
	        this.paired = source["paired"];
	        this.connected = source["connected"];
	        this.data_dir = source["data_dir"];
	        this.download_dir = source["download_dir"];
	        this.fingerprint = source["fingerprint"];
	    }
	}
	
	

}

export namespace protocol {
	
	export class AppVolumeSummary {
	    id: string;
	    name: string;
	    volume: number;
	    muted: boolean;
	
	    static createFrom(source: any = {}) {
	        return new AppVolumeSummary(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.volume = source["volume"];
	        this.muted = source["muted"];
	    }
	}
	export class AudioDeviceSummary {
	    id: string;
	    name: string;
	    default: boolean;
	
	    static createFrom(source: any = {}) {
	        return new AudioDeviceSummary(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.name = source["name"];
	        this.default = source["default"];
	    }
	}
	export class DeviceHealth {
	    type: string;
	    device_id: string;
	    battery: number;
	    charging: boolean;
	    cpu_percent: number;
	    mem_percent: number;
	    network_type: string;
	    network_name: string;
	
	    static createFrom(source: any = {}) {
	        return new DeviceHealth(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.type = source["type"];
	        this.device_id = source["device_id"];
	        this.battery = source["battery"];
	        this.charging = source["charging"];
	        this.cpu_percent = source["cpu_percent"];
	        this.mem_percent = source["mem_percent"];
	        this.network_type = source["network_type"];
	        this.network_name = source["network_name"];
	    }
	}
	export class PlayerSummary {
	    id: string;
	    title: string;
	    artist: string;
	    playing: boolean;
	
	    static createFrom(source: any = {}) {
	        return new PlayerSummary(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.title = source["title"];
	        this.artist = source["artist"];
	        this.playing = source["playing"];
	    }
	}
	export class MediaState {
	    type: string;
	    playing: boolean;
	    has_media: boolean;
	    title: string;
	    artist: string;
	    app: string;
	    volume: number;
	    position: number;
	    duration: number;
	    artwork?: string;
	    players?: PlayerSummary[];
	    selected_player?: string;
	    audio_devices?: AudioDeviceSummary[];
	    app_volumes?: AppVolumeSummary[];
	
	    static createFrom(source: any = {}) {
	        return new MediaState(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.type = source["type"];
	        this.playing = source["playing"];
	        this.has_media = source["has_media"];
	        this.title = source["title"];
	        this.artist = source["artist"];
	        this.app = source["app"];
	        this.volume = source["volume"];
	        this.position = source["position"];
	        this.duration = source["duration"];
	        this.artwork = source["artwork"];
	        this.players = this.convertValues(source["players"], PlayerSummary);
	        this.selected_player = source["selected_player"];
	        this.audio_devices = this.convertValues(source["audio_devices"], AudioDeviceSummary);
	        this.app_volumes = this.convertValues(source["app_volumes"], AppVolumeSummary);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}
	
	export class WorkspaceAction {
	    type: string;
	    action: string;
	    modifiers?: string[];
	    key?: string;
	    path?: string;
	    url?: string;
	    command?: string;
	    window_id?: number;
	
	    static createFrom(source: any = {}) {
	        return new WorkspaceAction(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.type = source["type"];
	        this.action = source["action"];
	        this.modifiers = source["modifiers"];
	        this.key = source["key"];
	        this.path = source["path"];
	        this.url = source["url"];
	        this.command = source["command"];
	        this.window_id = source["window_id"];
	    }
	}
	export class WorkspaceButtonDef {
	    id: string;
	    label: string;
	    icon: string;
	    color_value: number;
	    action: WorkspaceAction;
	
	    static createFrom(source: any = {}) {
	        return new WorkspaceButtonDef(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.label = source["label"];
	        this.icon = source["icon"];
	        this.color_value = source["color_value"];
	        this.action = this.convertValues(source["action"], WorkspaceAction);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace storage {
	
	export class Settings {
	    auto_sync_clipboard: boolean;
	    receive_clipboard: boolean;
	    clipboard_max_chars: number;
	    auto_accept_files: boolean;
	    download_dir: string;
	    share_notifications: boolean;
	    receive_notifications: boolean;
	    allow_media_control: boolean;
	    allow_automation: boolean;
	    discoverable: boolean;
	    accept_new_pairing: boolean;
	    run_in_background: boolean;
	    start_on_login: boolean;
	    start_minimized: boolean;
	    show_advanced_features: boolean;
	
	    static createFrom(source: any = {}) {
	        return new Settings(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.auto_sync_clipboard = source["auto_sync_clipboard"];
	        this.receive_clipboard = source["receive_clipboard"];
	        this.clipboard_max_chars = source["clipboard_max_chars"];
	        this.auto_accept_files = source["auto_accept_files"];
	        this.download_dir = source["download_dir"];
	        this.share_notifications = source["share_notifications"];
	        this.receive_notifications = source["receive_notifications"];
	        this.allow_media_control = source["allow_media_control"];
	        this.allow_automation = source["allow_automation"];
	        this.discoverable = source["discoverable"];
	        this.accept_new_pairing = source["accept_new_pairing"];
	        this.run_in_background = source["run_in_background"];
	        this.start_on_login = source["start_on_login"];
	        this.start_minimized = source["start_minimized"];
	        this.show_advanced_features = source["show_advanced_features"];
	    }
	}

}

