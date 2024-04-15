//
// Copyright © 2024 Stream.io Inc. All rights reserved.
//

import Foundation

@available(iOS 13.0, *)
extension UserListState {
    struct Observer {
        private let query: UserListQuery
        let usersObserver: StateLayerDatabaseObserver<ListResult, ChatUser, UserDTO>
        
        init(query: UserListQuery, database: DatabaseContainer) {
            self.query = query
            usersObserver = StateLayerDatabaseObserver(
                databaseContainer: database,
                fetchRequest: UserDTO.userListFetchRequest(query: query),
                itemCreator: { try $0.asModel() }
            )
        }
        
        struct Handlers {
            let usersDidChange: (StreamCollection<ChatUser>) async -> Void
        }
        
        func start(with handlers: Handlers) {
            do {
                try usersObserver.startObserving(didChange: handlers.usersDidChange)
            } catch {
                log.error("Failed to start the user list observer for query: \(query)")
            }
        }
    }
}