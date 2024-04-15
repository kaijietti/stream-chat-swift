//
// Copyright © 2024 Stream.io Inc. All rights reserved.
//

import Foundation

@available(iOS 13.0, *)
extension MemberListState {
    struct Observer {
        let memberListObserver: StateLayerDatabaseObserver<ListResult, ChatChannelMember, MemberDTO>
        
        init(query: ChannelMemberListQuery, database: DatabaseContainer) {
            memberListObserver = StateLayerDatabaseObserver(
                databaseContainer: database,
                fetchRequest: MemberDTO.members(matching: query),
                itemCreator: { try $0.asModel() as ChatChannelMember }
            )
        }
        
        struct Handlers {
            let membersDidChange: (StreamCollection<ChatChannelMember>) async -> Void
        }
        
        func start(with handlers: Handlers) {
            do {
                try memberListObserver.startObserving(didChange: handlers.membersDidChange)
            } catch {
                log.error("Failed to start the member list observer with error \(error)")
            }
        }
    }
}