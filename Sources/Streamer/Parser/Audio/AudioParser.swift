//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import R2Shared
import UIKit

private extension [AVMetadataItem] {
    func filter(_ identifiers: [AVMetadataIdentifier]) -> [AVMetadataItem] {
        identifiers.flatMap { AVMetadataItem.metadataItems(from: self, filteredByIdentifier: $0) }
    }
}

public struct AudioPublicationAugmentedManifest {
    var manifest: Manifest
    var cover: UIImage?
}

public protocol AudioPublicationManifestAugmentor {
    func augment(_ baseManifest: Manifest, using fetcher: Fetcher) -> AudioPublicationAugmentedManifest
}

public final class AVAudioPublicationManifestAugmentor: AudioPublicationManifestAugmentor {
    public init() {}
    public func augment(_ baseManifest: Manifest, using fetcher: Fetcher) -> AudioPublicationAugmentedManifest
    {
        let avAssets = baseManifest.readingOrder.map { link in
            fetcher.get(link).file.map { AVURLAsset(url: $0, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }
        }
        let readingOrder = zip(baseManifest.readingOrder, avAssets).map { link, avAsset in
            guard let avAsset = avAsset else { return link }
            return link.copy(
                title: avAsset.metadata.filter([.commonIdentifierTitle]).first(where: { $0.stringValue }),
                bitrate: avAsset.tracks(withMediaType: .audio).first.map { Double($0.estimatedDataRate) },
                duration: avAsset.duration.seconds
            )
        }
        let avMetadata = avAssets.compactMap { $0?.metadata }.reduce([], +)

        let metadata = baseManifest.metadata.copy(
            title: avMetadata.filter([.commonIdentifierTitle, .id3MetadataAlbumTitle]).first(where: { $0.stringValue }) ?? baseManifest.metadata.title,
            subtitle: avMetadata.filter([.id3MetadataSubTitle, .iTunesMetadataTrackSubTitle]).first(where: { $0.stringValue }),
            modified: avMetadata.filter([.commonIdentifierLastModifiedDate]).first(where: { $0.dateValue }),
            published: avMetadata.filter([.commonIdentifierCreationDate, .id3MetadataDate]).first(where: { $0.dateValue }),
            languages: avMetadata.filter([.commonIdentifierLanguage, .id3MetadataLanguage]).compactMap(\.stringValue).removingDuplicates(),
            subjects: avMetadata.filter([.commonIdentifierSubject]).compactMap(\.stringValue).removingDuplicates().map { Subject(name: $0) },
            authors: avMetadata.filter([.commonIdentifierAuthor, .iTunesMetadataAuthor]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) },
            artists: avMetadata.filter([.commonIdentifierArtist, .id3MetadataOriginalArtist, .iTunesMetadataArtist, .iTunesMetadataOriginalArtist]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) },
            illustrators: avMetadata.filter([.iTunesMetadataAlbumArtist]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) },
            contributors: avMetadata.filter([.commonIdentifierContributor]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) },
            publishers: avMetadata.filter([.commonIdentifierPublisher, .id3MetadataPublisher, .iTunesMetadataPublisher]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) },
            description: avMetadata.filter([.commonIdentifierDescription, .iTunesMetadataDescription]).first?.stringValue,
            duration: avAssets.reduce(0) { duration, avAsset in
                guard let duration = duration, let avAsset = avAsset else { return nil }
                return duration + avAsset.duration.seconds
            }
        )
        let manifest = baseManifest.copy(metadata: metadata, readingOrder: readingOrder)
        let cover = avMetadata.filter([.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt]).first(where: { $0.dataValue.flatMap(UIImage.init(data:)) })
        return .init(manifest: manifest, cover: cover)
    }
}

/// Parses an audiobook Publication from an unstructured archive format containing audio files,
/// such as ZAB (Zipped Audio Book) or a simple ZIP.
///
/// It can also work for a standalone audio file.
public final class AudioParser: PublicationParser {
    public init(manifestAugmentor: AudioPublicationManifestAugmentor = AVAudioPublicationManifestAugmentor()) {
        self.manifestAugmentor = manifestAugmentor
    }

    private let manifestAugmentor: AudioPublicationManifestAugmentor

    public func parse(asset: PublicationAsset, fetcher: Fetcher, warnings: WarningLogger?) throws -> Publication.Builder? {
        guard accepts(asset, fetcher) else {
            return nil
        }

        let defaultReadingOrder = fetcher.links
            .filter { !ignores($0) && $0.mediaType.isAudio }
            .sorted { $0.href.localizedCaseInsensitiveCompare($1.href) == .orderedAscending }

        guard !defaultReadingOrder.isEmpty else {
            return nil
        }

        let defaultManifest = Manifest(
            metadata: Metadata(
                conformsTo: [.audiobook],
                title: fetcher.guessTitle(ignoring: ignores) ?? asset.name
            ),
            readingOrder: defaultReadingOrder
        )

        let augmented = manifestAugmentor.augment(defaultManifest, using: fetcher)

        return Publication.Builder(
            mediaType: .zab,
            format: .cbz,
            manifest: augmented.manifest,
            fetcher: fetcher,
            servicesBuilder: .init(
                cover: augmented.cover.map(GeneratedCoverService.makeFactory(cover:)),
                locator: AudioLocatorService.makeFactory()
            )
        )
    }

    private func accepts(_ asset: PublicationAsset, _ fetcher: Fetcher) -> Bool {
        if asset.mediaType() == .zab {
            return true
        }

        // Checks if the fetcher contains only bitmap-based resources.
        return !fetcher.links.isEmpty
            && fetcher.links.allSatisfy { ignores($0) || $0.mediaType.isAudio }
    }

    private func ignores(_ link: Link) -> Bool {
        let url = URL(fileURLWithPath: link.href)
        let filename = url.lastPathComponent
        let allowedExtensions = ["asx", "bio", "m3u", "m3u8", "pla", "pls", "smil", "txt", "vlc", "wpl", "xspf", "zpl"]

        return allowedExtensions.contains(url.pathExtension.lowercased())
            || filename.hasPrefix(".")
            || filename == "Thumbs.db"
    }

    @available(*, unavailable, message: "Not supported for `AudioParser`")
    public static func parse(at url: URL) throws -> (PubBox, PubParsingCallback) {
        fatalError("Not supported for `AudioParser`")
    }
}
