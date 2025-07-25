//
//  VelociPlayer.swift
//  VelociPlayer
//
//  Created by Ethan Humphrey on 1/21/22.
//

import Foundation
import AVFoundation
import MediaPlayer
import Combine

// This typealias allows client applications to use this type without importing `CMTime`
public typealias VPTime = CMTime

/// An audio/video player that makes playback easily to implement, utilizing Combine to subscribe to changes.
@MainActor
public class VelociPlayer: AVPlayer, ObservableObject {
    
    // MARK: - Variables
    /// The playback progress of the current item: Ranges from 0 to 1.
    @Published public internal(set) var progress = 0.0
    
    /// The playback time of the current item.
    @Published public internal(set) var time = VPTime(seconds: 0, preferredTimescale: 10_000)
    
    /// Indicates if playback is currently paused.
    @Published public internal(set) var isPaused = true
    
    /// Indicates if the player is currently loading content.
    @Published public internal(set) var isBuffering = false
    
    /// The furthest point of the current item that is currently buffered.
    @Published public internal(set) var bufferTime = VPTime(seconds: 0, preferredTimescale: 10_000)
    
    /// The furthest point of the current item that is currently buffered as a percentage: Ranges from 0 to 1.
    @Published public internal(set) var bufferProgress = 0.0
    
    /// The total length of the currently playing item.
    @Published public internal(set) var duration = VPTime(seconds: 0, preferredTimescale: 10_000)
    
    /// The caption that should be displayed for the current playback time.
    @Published public internal(set) var currentCaption: Caption?
    
    /// An error property that updates whenever the player encounters an error
    @Published public internal(set) var currentError: VelociPlayerError?
    
    /// Specifies whether the player should automatically begin playback once the item has finished loading.
    public var autoPlay = false
    
    /// Specifies the time at which the player should start playback.
    public var startTime: VPTime?
    
    /// Determines how many seconds the `rewind` and `skipForward` commands should skip. The default is `10.0`.
    public var seekInterval = 10.0 {
        didSet {
            guard displayInSystemPlayer else { return }
            if case .skip = nowPlayingConfiguration.previousControl {
                MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
            }
            if case .skip = nowPlayingConfiguration.forwardControl {
                MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
            }
        }
    }
    
    /// Determines whether the player should integrate with the system to allow playback controls from Control Center and the Lock Screen, among other places.
    public var displayInSystemPlayer = false {
        didSet {
            if displayInSystemPlayer && timeObserver != nil {
                setUpNowPlayingControls()
            } else {
                removeFromNowPlaying()
            }
        }
    }
    
    #if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
    /// Specifies the audio mode for the system. Set this to `.default` for standard audio and `.moviePlayback` for videos.
    public var audioMode: AVAudioSession.Mode = .default {
        didSet {
            setAVCategory()
        }
    }
    
    /// Specifies the audio category for the system. The default is `.playback` which should work for most use cases.
    public var audioCategory: AVAudioSession.Category = .playback {
        didSet {
            setAVCategory()
        }
    }
    
    /// Specifies the audio category options for the system. Use `[.mixWithOthers, .duckOthers]` to allow background audio to continue at reduced volume.
    public var audioCategoryOptions: AVAudioSession.CategoryOptions = [] {
        didSet {
            setAVCategory()
        }
    }
    #endif
    
    /// The source URL of the media file
    public var mediaURL: URL? {
        didSet {
            mediaURLChanged()
        }
    }
    
    /// Specifies which controls are available to the user in the Now Playing controller.
    public var nowPlayingConfiguration = NowPlayingConfiguration() {
        didSet {
            guard displayInSystemPlayer else { return }
            setUpNowPlayingControls()
        }
    }
    
    /// An array of all decoded captions that can be displayed for the current item.
    public var allCaptions: [Caption]?
    
    internal var timeObserver: Any?
    internal var subscribers = [AnyCancellable]()
    internal var currentItemSubscribers = [AnyCancellable]()
    internal var commandTargets = [MPRemoteCommand: Any]()
    
    internal var nowPlayingInfo: [String: Any]? {
        didSet {
            guard displayInSystemPlayer else { return }
            
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }
    
    // MARK: - Initialization
    public init(
        autoPlay: Bool = false,
        mediaURL: URL? = nil,
        startTime: VPTime? = nil
    ) {
        super.init()
        volume = 1.0
        self.autoPlay = autoPlay
        self.mediaURL = mediaURL
        self.startTime = startTime
        
        self.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.statusChanged()
            }
            .store(in: &subscribers)
        
        self.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.prepareNewPlayerItem()
            }
            .store(in: &subscribers)
        
        mediaURLChanged()
    }
    
    internal func prepareForPlayback() {
        self.currentError = nil
        self.isBuffering = true
        Task.detached {
            if let startTime = await self.startTime {
               await self.seek(to: startTime)
            }
            
            await self.preroll(atRate: 1.0)
            
            await MainActor.run {
                self.isBuffering = true
                if self.autoPlay {
                    self.play()
                }
            }
        }
    }
    
    internal func updateCurrentItemDuration() async {
        await currentItem?.asset.loadValues(forKeys: ["duration"])
        
        if let duration = currentItem?.asset.duration {
            self.duration = duration
        }
    }
    
    internal func setAVCategory() {
        #if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
        let audioCategory = self.audioCategory
        let audioMode = self.audioMode
        let categoryOptions = self.audioCategoryOptions
        Task.detached { [audioCategory, audioMode, categoryOptions] in
            try? AVAudioSession.sharedInstance().setCategory(
                audioCategory,
                mode: audioMode,
                options: categoryOptions
            )
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        }
        #endif
    }
}