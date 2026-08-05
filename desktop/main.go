package main

import (
	"context"
	"embed"
	"log"
	"os"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
	"github.com/getlantern/systray"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed build/windows/icon.ico
var iconData []byte

var wailsCtx context.Context

func main() {
	log.SetFlags(log.Ltime)

	// --background is what the login-startup entry passes, so the app comes up
	// syncing but out of the way.
	startHidden := false
	for _, arg := range os.Args[1:] {
		if arg == "--background" || arg == "-background" {
			startHidden = true
		}
	}

	service := NewWeDropService()

	go systray.Run(onReady, onExit)

	err := wails.Run(&options.App{
		Title:     "WeDrop",
		Width:     1180,
		Height:    780,
		MinWidth:  940,
		MinHeight: 620,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 8, G: 11, B: 20, A: 1},
		StartHidden:      startHidden,
		// Closing the window leaves the app running so clipboard sync, file
		// receipt and notification mirroring keep working — that is the whole
		// point of an always-on ecosystem app. OnBeforeClose decides whether a
		// close really means quit.
		HideWindowOnClose: false,
		OnStartup: func(ctx context.Context) {
			wailsCtx = ctx
			service.startup(ctx)
		},
		OnBeforeClose: func(ctx context.Context) bool {
			if service.currentSettings().RunInBackground {
				wailsRuntime.WindowHide(ctx)
				return true // veto the close; keep running in the background
			}
			return false
		},
		OnShutdown: service.shutdown,
		Bind: []interface{}{
			service,
		},
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
		},
	})

	if err != nil {
		log.Fatalf("WeDrop could not start: %v", err)
	}
}

func onReady() {
	systray.SetIcon(iconData)
	systray.SetTitle("WeDrop")
	systray.SetTooltip("WeDrop - File Sharing")

	mShow := systray.AddMenuItem("Show WeDrop", "Show the main window")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Quit WeDrop")

	go func() {
		for {
			select {
			case <-mShow.ClickedCh:
				if wailsCtx != nil {
					wailsRuntime.WindowShow(wailsCtx)
				}
			case <-mQuit.ClickedCh:
				if wailsCtx != nil {
					wailsRuntime.Quit(wailsCtx)
				}
				systray.Quit()
				return
			}
		}
	}()
}

func onExit() {
	// Clean up here if necessary
}
