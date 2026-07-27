export namespace protocol {
	
	export class DiscoveryMessage {
	    type: string;
	    version: string;
	    device_id: string;
	    name: string;
	    platform: string;
	    ip: string;
	    tcp_port: number;
	    public_key: string;
	
	    static createFrom(source: any = {}) {
	        return new DiscoveryMessage(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.type = source["type"];
	        this.version = source["version"];
	        this.device_id = source["device_id"];
	        this.name = source["name"];
	        this.platform = source["platform"];
	        this.ip = source["ip"];
	        this.tcp_port = source["tcp_port"];
	        this.public_key = source["public_key"];
	    }
	}
	export class PairingReq {
	    type: string;
	    device_id: string;
	    name: string;
	    public_key: string;
	
	    static createFrom(source: any = {}) {
	        return new PairingReq(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.type = source["type"];
	        this.device_id = source["device_id"];
	        this.name = source["name"];
	        this.public_key = source["public_key"];
	    }
	}
	export class PairingResp {
	    type: string;
	    device_id: string;
	    accepted: boolean;
	
	    static createFrom(source: any = {}) {
	        return new PairingResp(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.type = source["type"];
	        this.device_id = source["device_id"];
	        this.accepted = source["accepted"];
	    }
	}

}

export namespace storage {
	
	export class DeviceConfig {
	    device_id: string;
	    name: string;
	    platform: string;
	    public_key: string;
	    private_key: string;
	    auto_sync_clipboard: boolean;
	
	    static createFrom(source: any = {}) {
	        return new DeviceConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.device_id = source["device_id"];
	        this.name = source["name"];
	        this.platform = source["platform"];
	        this.public_key = source["public_key"];
	        this.private_key = source["private_key"];
	        this.auto_sync_clipboard = source["auto_sync_clipboard"];
	    }
	}
	export class TrustedDevice {
	    device_id: string;
	    name: string;
	    public_key: string;
	    trusted: boolean;
	
	    static createFrom(source: any = {}) {
	        return new TrustedDevice(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.device_id = source["device_id"];
	        this.name = source["name"];
	        this.public_key = source["public_key"];
	        this.trusted = source["trusted"];
	    }
	}

}

