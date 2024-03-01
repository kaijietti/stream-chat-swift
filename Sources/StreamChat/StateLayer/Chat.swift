//
// Copyright © 2024 Stream.io Inc. All rights reserved.
//

import Foundation

@available(iOS 13.0, *)
public final class Chat {
    private let attachmentQueueUploader: AttachmentQueueUploader
    private let authenticationRepository: AuthenticationRepository
    private let channelUpdater: ChannelUpdater
    private let databaseContainer: DatabaseContainer
    private let eventNotificationCenter: EventNotificationCenter
    private let messageEditor: MessageEditor
    private let messageSender: MessageSender
    private let messageUpdater: MessageUpdater
    private let readStateSender: ReadStateSender
    private let typingEventsSender: TypingEventsSender
    
    private var messageStates = NSMapTable<NSString, MessageState>(valueOptions: .weakMemory)
    
    public let cid: ChannelId
    public let channelListQuery: ChannelListQuery?
    public let channelQuery: ChannelQuery
    
    init(
        cid: ChannelId,
        channelQuery: ChannelQuery,
        channelListQuery: ChannelListQuery?,
        messageOrdering: MessageOrdering = .topToBottom,
        channelUpdater: ChannelUpdater,
        client: ChatClient,
        environment: Environment = .init()
    ) {
        attachmentQueueUploader = client.attachmentQueueUploader
        authenticationRepository = client.authenticationRepository
        self.channelQuery = ChannelQuery(cid: cid, channelQuery: channelQuery)
        self.channelListQuery = channelListQuery
        self.cid = cid
        self.channelUpdater = channelUpdater
        eventNotificationCenter = client.eventNotificationCenter
        databaseContainer = client.databaseContainer
        messageEditor = client.messageEditor
        messageSender = client.messageSender
        messageUpdater = environment.messageUpdaterBuilder(
            client.config.isLocalStorageEnabled,
            client.messageRepository,
            client.databaseContainer,
            client.apiClient
        )
        readStateSender = environment.readStateSenderBuilder(
            cid,
            channelUpdater,
            client.authenticationRepository,
            client.messageRepository
        )
        typingEventsSender = environment.typingEventsSenderBuilder(
            client.databaseContainer,
            client.apiClient
        )
        state = environment.chatStateBuilder(
            cid,
            channelQuery,
            messageOrdering,
            client.databaseContainer,
            client.eventNotificationCenter,
            channelUpdater.paginationState
        )
    }
    
    public internal(set) var state: ChatState
    
    // MARK: - Deleting the Channel
    
    /// Deletes the channel.
    ///
    /// This marks the channel as deleted and hides all the messages.
    ///
    /// - Note: If you recreate this channel, it will show up empty. Recovering old messages is not supported.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func delete() async throws {
        try await channelUpdater.deleteChannel(cid: cid)
    }
    
    // MARK: - Disabling/Freezing the Channel
    
    /// Freezes the channel which disallows sending new messages and adding or deleting reactions.
    ///
    /// Sending a message to a frozen channel will result in a error. Sending and deleting
    /// reactions to frozen channels will result in a 403 (Not Allowed) error. User roles
    /// with the `UseFrozenChannel` permission are still able to use frozen channels as if they
    /// weren't frozen. By default no user role has the `UseFrozenChannel` permission.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func freeze() async throws {
        try await channelUpdater.freezeChannel(true, cid: cid)
    }
    
    /// Removes the frozen channel restriction and enables sending new messages and adding or deleting reactions.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func unfreeze() async throws {
        try await channelUpdater.freezeChannel(false, cid: cid)
    }
    
    // MARK: - Invites
    
    /// Accepts a pending invite and adds the current user as a member of the channel.
    ///
    /// - Note: Unread counts are not incremented for the channel for which the user is a member of but has a pending invite.
    /// - Note: Pending invites can be queried by setting the ``Filter`` to `.equal("invite", to: "pending")`.
    ///
    /// - Parameter systemMessage: A system message to be added after accepting the invite.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func acceptInvite(with systemMessage: String? = nil) async throws {
        try await channelUpdater.acceptInvite(cid: cid, message: systemMessage)
    }
    
    /// Invite users to the channel.
    ///
    /// Upon invitation, the invited user will receive a notification that they were invited to the this channel.
    ///
    /// - Parameter members: An array of user ids that will be invited to the channel.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func inviteMembers(_ members: [UserId]) async throws {
        try await channelUpdater.inviteMembers(cid: cid, userIds: Set(members))
    }
    
    /// Rejects a pending invite and does not add the current user as a member of the channel.
    ///
    /// - Note: Pending invites can be queried by setting the ``Filter`` to `.equal("invite", to: "pending")`.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func rejectInvite() async throws {
        try await channelUpdater.rejectInvite(cid: cid)
    }
    
    // MARK: - Members
    
    /// Adds the given users as members.
    ///
    /// - Note: You can only add up to 100 members at once.
    ///
    /// - Parameters:
    ///   - members: An array of user ids that will be added to the channel.
    ///   - systemMessage: A system message to be added after adding members.
    ///   - hideHistory: If true, the previous history is available for added members, otherwise they do not see the history. The default value is false.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func addMembers(_ members: [UserId], systemMessage: String? = nil, hideHistory: Bool = false) async throws {
        let currentUserId = authenticationRepository.currentUserId
        try await channelUpdater.addMembers(currentUserId: currentUserId, cid: cid, userIds: Set(members), message: systemMessage, hideHistory: hideHistory)
    }
    
    /// Removes the given users from the channel members.
    ///
    /// - Parameters:
    ///   - members: An array of user ids that will be removed from the channel.
    ///   - systemMessage: A system message to be added after removing members.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func removeMembers(_ members: [UserId], systemMessage: String? = nil) async throws {
        let currentUserId = authenticationRepository.currentUserId
        try await channelUpdater.removeMembers(currentUserId: currentUserId, cid: cid, userIds: Set(members), message: systemMessage)
    }
    
    // MARK: - Messages
    
    /// Deletes the specified message.
    ///
    /// Messages can be soft deleted or hard deleted. Note that deleting a message doesn't delete its attachments.
    ///
    /// - Parameters:
    ///   - message: The id of the message to delete.
    ///   - hard: True, if the message should be permanently deleted. The default value is false. The recommend approach is to always do a soft delete (hard = false).
    ///   You can control the UI Visibility of the deleted message in the client side.
    ///
    /// - Warning: If you hard delete the message, the message will be permanently lost since it will be erased from the backend's database.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func deleteMessage(_ message: MessageId, hard: Bool = false) async throws {
        try await messageUpdater.deleteMessage(messageId: message, hard: hard)
    }
    
    /// Resends a failed message.
    ///
    /// The ``sendMessage`` method can fail but the message is not discarded. Failed messages are kept locally and can be retried.
    ///
    /// - Parameter message: The id of the message to resend.
    ///
    /// - Throws: An error while sending a message to the Stream API.
    public func resendMessage(_ message: MessageId) async throws {
        try await messageUpdater.resendMessage(with: message)
        try await messageEditor.waitForAPIRequest(messageId: message)
    }
    
    /// Resends a failed attachment.
    ///
    /// - Parameter attachment: The id of the attachment.
    ///
    /// - Throws: An error while sending a message to the Stream API.
    public func resendAttachment(_ attachment: AttachmentId) async throws {
        try await messageUpdater.resendAttachment(with: attachment)
        try await attachmentQueueUploader.waitForAPIRequest(attachmentId: attachment)
    }
    
    /// Sends a message to channel.
    ///
    /// The send message method waits until the network request has finished to Stream API.
    ///
    /// - Parameters:
    ///   - text: Text of the message.
    ///   - attachments: An array of the attachments for the message.
    ///     `Note`: can be built-in types, custom attachment types conforming to `AttachmentEnvelope` protocol
    ///     and `ChatMessageAttachmentSeed`s.
    ///   - replyTo: An id of the replied (quoted) message.
    ///   - mentions: An array of mentioned user ids.
    ///   - pinning: If pinning configuration is set, the message is pinned to the channel.
    ///   - extraData: Additional extra data of the message object.
    ///   - silent: If true, the message doesn't increase the unread messages count and mark a channel as unread.
    ///   - skipPushNotification: If true, skips sending push notification to channel members.
    ///   - skipEnrichURL: If true, the url preview won't be attached to the message.
    ///   - messageId: A custom id for the sent message. By default, it is automatically generated by Stream.
    ///
    /// - Note: If sending a message fails, the message is not discarded. Failed messages are kept locally and can be retried.
    ///
    /// - Throws: An error while sending a message to the Stream API.
    /// - Returns: An instance of `ChatMessage` which was delivered to the channel.
    @discardableResult
    public func sendMessage(
        with text: String,
        attachments: [AnyAttachmentPayload] = [],
        replyTo: MessageId? = nil,
        mentions: [UserId] = [],
        pinning: MessagePinning? = nil,
        extraData: [String: RawJSON] = [:],
        silent: Bool = false,
        skipPushNotification: Bool = false,
        skipEnrichURL: Bool = false,
        messageId: MessageId? = nil
    ) async throws -> ChatMessage {
        let message = try await channelUpdater.createNewMessage(
            in: cid,
            messageId: messageId,
            text: text,
            pinning: pinning,
            isSilent: silent,
            command: nil,
            arguments: nil,
            attachments: attachments,
            mentionedUserIds: mentions,
            quotedMessageId: replyTo,
            skipPush: skipPushNotification,
            skipEnrichUrl: skipEnrichURL,
            extraData: extraData
        )
        eventNotificationCenter.process(NewMessagePendingEvent(message: message))
        return try await messageSender.waitForAPIRequest(messageId: message.id)
    }
    
    /// Edits the specified message in the channel.
    ///
    /// - Parameters:
    ///   - message: The id of the message to edit.
    ///   - text: Text of the message.
    ///   - attachments: An array of the attachments for the message.
    ///   - extraData: Additional extra data of the message object.
    ///   - skipEnrichURL: If true, the url preview won't be attached to the message.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func updateMessage(_ message: MessageId, with text: String, attachments: [AnyAttachmentPayload] = [], extraData: [String: RawJSON]? = nil, skipEnrichURL: Bool = false) async throws {
        try await messageUpdater.editMessage(messageId: message, text: text, skipEnrichUrl: skipEnrichURL, attachments: attachments, extraData: extraData)
        try await messageEditor.waitForAPIRequest(messageId: message)
    }
    
    // MARK: - Message Loading
    
    /// Loads messages for the specified pagination parameters and updates ``ChatState.messages``.
    ///
    /// - Parameters:
    ///   - message: The parent message id which has replies.
    ///   - pagination: The pagination configuration which includes limit and cursor.
    ///
    /// - Throws: An error while communicating with the Stream API.
    /// - Returns: An array of messages for the pagination.
    public func loadMessages(with pagination: MessagesPagination) async throws -> [ChatMessage] {
        try await channelUpdater.loadMessages(with: channelQuery, pagination: pagination)
    }
    
    // MARK: -
    
    /// Loads messages for the first page and updates ``ChatState.messages``.
    ///
    /// - Note: Loading the first page resets the ``ChatState.messages``.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadMessagesFirstPage() async throws {
        try await channelUpdater.loadMessagesFirstPage(with: channelQuery)
    }
    
    /// Loads more messages before the specified message to ``ChatState.messages``.
    ///
    /// - Parameters:
    ///   - messageId: The message id of the message from which older messages are loaded.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadMessages(before messageId: MessageId? = nil, limit: Int? = nil) async throws {
        try await channelUpdater.loadMessages(before: messageId, limit: limit, channelQuery: channelQuery, loaded: state.messages)
    }
    
    /// Loads more messages after the specified message to ``ChatState.messages``.
    ///
    /// - Parameters:
    ///   - messageId: The message id of the message from which newer messages are loaded.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadMessages(after messageId: MessageId? = nil, limit: Int? = nil) async throws {
        try await channelUpdater.loadMessages(after: messageId, limit: limit, channelQuery: channelQuery, loaded: state.messages)
    }
    
    /// Loads messages around the given message id to ``ChatState.messages``.
    ///
    /// Useful for jumping to a message which hasn't been loaded yet.
    ///
    /// - Note: Jumping to a messages resets the ``ChatState.messages``.
    ///
    /// - Parameters:
    ///   - messageId: The message id of the middle message in the loaded list of messages.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadMessages(around messageId: MessageId, limit: Int? = nil) async throws {
        try await channelUpdater.loadMessages(around: messageId, limit: limit, channelQuery: channelQuery, loaded: state.messages)
    }
    
    // MARK: - Message Attachment Actions
    
    /// Invokes the ephermal action specified by the attachment.
    ///
    /// - Parameters:
    ///   - message: The id of the message with the action.
    ///   - action: The ephermal action to be invoked.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func sendMessageAction(in message: MessageId, action: AttachmentAction) async throws {
        try await messageUpdater.dispatchEphemeralMessageAction(cid: cid, messageId: message, action: action)
    }
    
    // MARK: - Message Flagging
    
    /// Flags the specified message and forwards it for moderation.
    ///
    /// - Note: Any user is allowed to flag a message.
    ///
    /// - Parameter message: The id of the message to be flagged.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func flagMessage(_ message: MessageId) async throws {
        try await messageUpdater.flagMessage(true, with: message, in: cid)
    }
    
    /// Removes the flag from the specified message.
    ///
    /// - Parameter message: The id of the message to be unflagged.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func unflagMessage(_ message: MessageId) async throws {
        try await messageUpdater.flagMessage(false, with: message, in: cid)
    }
    
    // MARK: - Message Rich Content
    
    /// Retrieve the link attachment preview for the specified URL.
    ///
    /// - Returns: The data present in the [Open Graph metadata](https://ogp.me).
    /// - Throws: An error while communicating with the Stream API.
    public func enrichURL(_ url: URL) async throws -> LinkAttachmentPayload {
        try await channelUpdater.enrichUrl(url)
    }
    
    // MARK: - Message Pinning
    
    /// Pins the message to the channel until the specified date.
    ///
    /// - Note: To pin the message user has to have `PinMessage` permission.
    ///
    /// - Parameters:
    ///   - message: The id of the message to be pinned.
    ///   - pinning: The pinning expiration information. Supports an infinite expiration, setting a date, or the amount of time a message is pinned.
    ///
    /// - Throws: An error while communicating with the Stream API or missing required capabilities.
    public func pinMessage(_ message: MessageId, pinning: MessagePinning) async throws {
        try state.channel?.requireCapability(of: .pinMessage)
        try await messageUpdater.pinMessage(messageId: message, pinning: pinning)
        try await messageEditor.waitForAPIRequest(messageId: message)
    }
    
    /// Removes the message from the channel's pinned messages.
    ///
    /// - Note: To unpin the message user has to have `PinMessage` permission.
    ///
    /// - Parameter message: The id of the message to unpin.
    ///
    /// - Throws: An error while communicating with the Stream API or missing required capabilities.
    public func unpinMessage(_ message: MessageId) async throws {
        try state.channel?.requireCapability(of: .pinMessage)
        try await messageUpdater.unpinMessage(messageId: message)
        try await messageEditor.waitForAPIRequest(messageId: message)
    }
    
    /// Loads pinned messages for the specified pagination options, sorting order, and limit.
    ///
    /// - Parameters:
    ///   - pagination: The pagination option used for retrieving pinned messages. If nil, most recently pinned messages are returned.
    ///   - sort: The sorting order for pinned messages. The default value is descending by `pinned_at` field.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    /// - Returns: An array of pinned messages for the specified pagination.
    public func loadPinnedMessages(for pagination: PinnedMessagesPagination? = nil, sort: [Sorting<PinnedMessagesSortingKey>] = [], limit: Int = .messagesPageSize) async throws -> [ChatMessage] {
        let query = PinnedMessagesQuery(pageSize: limit, sorting: sort, pagination: pagination)
        return try await channelUpdater.loadPinnedMessages(in: cid, query: query)
    }
    
    // MARK: - Message Reactions
    
    /// Removes a reaction with a specified type from a message.
    /// - Parameters:
    ///   - message: The id of the message to remove the reaction from.
    ///   - type: The type that describes a message reaction. Common examples are: “like”, “love”, “smile”, etc. An user can have only 1 reaction of each type per message.
    public func deleteReaction(from message: MessageId, with type: MessageReactionType) async throws {
        try await messageUpdater.deleteReaction(type, messageId: message)
    }
    
    /// Adds a reaction to the specified message.
    ///
    /// - Note: Custom data for reactions is limited to 1 KB.
    ///
    /// - Parameters:
    ///   - message: The id of the message to send the reaction.
    ///   - type: The type that describes a message reaction. Common examples are: “like”, “love”, “smile”, etc. An user can have only 1 reaction of each type per message.
    ///   - score: The score of the reaction for cumulative reactions (example: n number of claps).
    ///   - enforceUnique: If `true`, the added reaction will replace all reactions the user has (if any) on this message.
    ///   - extraData: The reaction's extra data.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func sendReaction(to message: MessageId, with type: MessageReactionType, score: Int = 1, enforceUnique: Bool = false, extraData: [String: RawJSON] = [:]) async throws {
        try await messageUpdater.addReaction(type, score: score, enforceUnique: enforceUnique, extraData: extraData, messageId: message)
    }
    
    /// Loads reactions for the specified message and pagination parameters.
    ///
    /// All the currently loaded reactions can be accessed through ``MessageState.reactions``.
    ///
    /// - Parameters:
    ///   - messageId: The id of the message to load reactions.
    ///   - pagination: The pagination configuration which includes limit and offset or cursor.
    ///
    /// - Throws: An error while communicating with the Stream API.
    /// - Returns: An array of reactions for given limit and offset.
    public func loadReactions(of messageId: MessageId, pagination: Pagination) async throws -> [ChatMessageReaction] {
        try await messageUpdater.loadReactions(cid: cid, messageId: messageId, pagination: pagination)
    }
    
    // MARK: - Message Reading
    
    /// Marks all the unread messages in the channel as read.
    ///
    /// - Throws: An error while communicating with the Stream API or missing required capabilities.
    public func markRead() async throws {
        guard let channel = state.channel else { throw ClientError.ChannelDoesNotExist(cid: cid) }
        try channel.requireCapability(of: .readEvents)
        try await readStateSender.markRead(channel)
    }
    
    /// Marks all the messages after and including the specified message as unread.
    ///
    /// - Parameter messageId: The id of the first message that will be marked as unread.
    ///
    /// - Throws: An error while communicating with the Stream API or missing required capabilities.
    public func markUnread(from messageId: MessageId) async throws {
        guard let channel = state.channel else { throw ClientError.ChannelDoesNotExist(cid: cid) }
        try channel.requireCapability(of: .readEvents)
        try await readStateSender.markUnread(from: messageId, in: channel)
    }
    
    // MARK: - Message Replies
    
    /// Loads replies for the specified message and pagination parameters and updates ``MessageState.replies``.
    ///
    /// - Parameters:
    ///   - messageId: The parent message id which has replies.
    ///   - pagination: The pagination configuration which includes limit and cursor.
    ///
    /// - Throws: An error while communicating with the Stream API.
    /// - Returns: An array of messages for the pagination.
    public func loadReplies(of messageId: MessageId, pagination: MessagesPagination) async throws -> [ChatMessage] {
        let messageState = try await makeMessageState(for: messageId)
        return try await messageUpdater.loadReplies(of: messageId, pagination: pagination, cid: cid, paginationStateHandler: messageState.replyPaginationHandler)
    }

    // MARK: -
    
    /// Loads replies for the first page of the specified message and updates ``MessageState.replies``.
    ///
    /// - Note: Loading the first page resets the ``MessageState.replies``.
    ///
    /// - Parameters:
    ///   - message: The parent message id which has replies.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadRepliesFirstPage(of messageId: MessageId, limit: Int? = nil) async throws {
        let messageState = try await makeMessageState(for: messageId)
        return try await messageUpdater.loadRepliesFirstPage(of: messageId, limit: limit, cid: cid, paginationStateHandler: messageState.replyPaginationHandler)
    }
    
    /// Loads more replies before the specified reply id to ``MessageState.replies``.
    ///
    /// - Parameters:
    ///   - messageId: The parent message id which has replies.
    ///   - replyId: The message id of the reply from which older messages are loaded. If nil, the oldest currently loaded message id in ``MessageState.replies`` is used.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadReplies(of messageId: MessageId, before replyId: MessageId, limit: Int? = nil) async throws {
        let messageState = try await makeMessageState(for: messageId)
        return try await messageUpdater.loadReplies(of: messageId, before: replyId, limit: limit, cid: cid, paginationStateHandler: messageState.replyPaginationHandler)
    }
    
    /// Loads more replies after the specified reply id to ``MessageState.replies``.
    ///
    /// - Parameters:
    ///   - messageId: The parent message id which has replies.
    ///   - replyId: The message id of the reply from which newer messages are loaded. If nil, the newest currently loaded message id in ``MessageState.replies`` is used.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadReplies(of messageId: MessageId, after replyId: MessageId, limit: Int? = nil) async throws {
        let messageState = try await makeMessageState(for: messageId)
        return try await messageUpdater.loadReplies(of: messageId, after: replyId, limit: limit, cid: cid, paginationStateHandler: messageState.replyPaginationHandler)
    }
    
    /// Loads replies around the specified reply id to ``MessageState.replies``.
    ///
    /// - Parameters:
    ///   - messageId: The parent message id which has replies.
    ///   - replyId: The message id of the reply around which older and newer messages are loaded.
    ///   - limit: The limit for the page size. The default limit is 25.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func loadReplies(of messageId: MessageId, around replyId: MessageId, limit: Int? = nil) async throws {
        let messageState = try await makeMessageState(for: messageId)
        return try await messageUpdater.loadReplies(of: messageId, around: replyId, limit: limit, cid: cid, paginationStateHandler: messageState.replyPaginationHandler)
    }
    
    // MARK: - Message State Observing
    
    /// Returns an observable message state for the specified message.
    ///
    /// The message state is refreshed before returning the observable state.
    ///
    /// - Note: Chat keeps a weak reference to the returned object. Calling the function multiple times
    /// with the same messageId might return the same instance of the ``MessageState``.
    ///
    /// - Parameter messageId: The message id for observing the state.
    ///
    /// - Returns: An instance of `MessageState` which conforms to the `ObservableObject`.
    @MainActor public func makeMessageState(for messageId: MessageId) async throws -> MessageState {
        if let state = messageStates.object(forKey: messageId as NSString) {
            return state
        } else {
            // Chat references MessageState weakly but MessageState references Chat strongly
            let message = try await messageUpdater.getMessage(cid: cid, messageId: messageId)
            let state = MessageState(
                message: message,
                chat: self,
                messageOrder: state.messageOrder,
                database: databaseContainer,
                replyPaginationHandler: MessagesPaginationStateHandler()
            )
            messageStates.setObject(state, forKey: messageId as NSString)
            return state
        }
    }
    
    // MARK: - Message Translations
    
    /// Translates the message to the given language.
    ///
    /// The translated text can be retrieved with `message.translations[language]`.
    ///
    /// - Note: The translated message is automatically inserted into ``ChatState.messages``.
    ///
    /// - Parameters:
    ///   - language: The language message text should be translated to.
    ///
    /// - Throws: An error while communicating with the Stream API
    @discardableResult public func translateMessage(_ message: MessageId, to language: TranslationLanguage) async throws -> ChatMessage {
        try await messageUpdater.translate(messageId: message, to: language)
    }
    
    // MARK: - Muting or Hiding the Channel
    
    /// Mutes the channel which disables push notifications and unread count for new messages.
    ///
    /// By default, mutes stay in place indefinitely until the user removes it.
    ///
    /// - Note: The list of muted channels and their expiration time is returned when the user connects.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func mute() async throws {
        try await channelUpdater.muteChannel(true, cid: cid)
    }
    
    /// Unmutes the channel which enables push notifications and unread count changes for new messages.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func unmute() async throws {
        try await channelUpdater.muteChannel(false, cid: cid)
    }
    
    /// Hide the channel which removes if from the query channel requests for that user until a new message is added.
    ///
    /// Hiding a channel is only available to members of that channel. Hidden channels may still have unread messages
    /// and you may wish to mark the channel as read prior to hiding it.
    ///
    /// Optionally you can also clear the entire message history of that channel for the user. This way,
    /// when a new message is received, it will be the only one present in the channel.
    ///
    /// - Note: You can retrieve the list of hidden channels using the `hidden` query parameter (``FilterKey.hidden``).
    ///
    /// - Parameter clearHistory: If true, the whole channel history is deleted. The default value is false.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func hide(clearHistory: Bool = false) async throws {
        try await channelUpdater.hideChannel(cid: cid, clearHistory: clearHistory)
    }
    
    /// Shows a previously hidden channel.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func show() async throws {
        try await channelUpdater.showChannel(cid: cid)
    }
    
    // MARK: - Throttling and Slow Mode
    
    /// Enables slow mode which limits how often members can post new messages to the channel.
    ///
    /// Slow mode helps reduce noise on a channel by limiting users to a maximum of 1 message per cooldown interval.
    /// The cooldown interval is configurable and can be anything between 1 and 120 seconds. If you enable slow mode
    /// and set the cooldown interval to 30 seconds a user will be able to post at most 1 message every 30 seconds.
    ///
    /// - Note: Moderators and admins are not restricted by the cooldown period and can post messages as usual.
    /// - Note: When a user posts a message during the cooldown period, the API returns an error message. You can
    /// avoid hitting the APIs and instead show such limitation on the send message UI directly. When slow mode is
    /// enabled, channels include a `cooldown` field containing the current cooldown period in seconds.
    ///
    /// - Parameter cooldownDuration: The time interval in seconds in which a user will be able to post at most 1 message.
    ///
    /// - Throws: An error while communicating with the Stream API or when setting an invalid duration.
    public func enableSlowMode(cooldownDuration: Int) async throws {
        guard cooldownDuration >= 1, cooldownDuration <= 120 else {
            throw ClientError.InvalidCooldownDuration()
        }
        try await channelUpdater.enableSlowMode(cid: cid, cooldownDuration: cooldownDuration)
    }
    
    /// Disables slow mode which removes the limits of how often members can post new messages to the channel.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func disableSlowMode() async throws {
        try await channelUpdater.enableSlowMode(cid: cid, cooldownDuration: 0)
    }
    
    // MARK: - Truncating the Channel
    
    /// Truncates messages from the channel.
    ///
    /// Truncating the channel removes all of the messages but does not affect the channel data or channel members.
    ///
    /// - SeeAlso: If you want to delete both channel and message data then use the ``delete()`` method instead.
    ///
    /// - Parameters:
    ///   - systemMessage: A system message to be added after truncating the channel.
    ///   - hardDelete: If true, messages are deleted, otherwise messages are hidden. The default value is set to true.
    ///   - skipPush: If true, push notification is not sent to channel members, otherwise push notification is sent. The default value is set to false.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func truncate(systemMessage: String? = nil, hardDelete: Bool = true, skipPush: Bool = false) async throws {
        try await channelUpdater.truncateChannel(cid: cid, skipPush: skipPush, hardDelete: hardDelete, systemMessage: systemMessage)
    }
    
    // MARK: - Typing Indicator
    
    /// Sends a `typing.start` event in this channel to the server.
    ///
    /// Keystroke events are throttled and `stopTyping(parentMessageId:)` is automatically called after a couple of seconds from the last keystroke event.
    ///
    /// - Parameter parentMessageId: A message id of the message in a thread the user is replying to.
    ///
    /// - Throws: An error while communicating with the Stream API or missing required capabilities.
    public func keystroke(parentMessageId: MessageId? = nil) async throws {
        try state.channel?.requireCapability(of: .sendTypingEvents)
        try await typingEventsSender.keystroke(in: cid, parentMessageId: parentMessageId)
    }
    
    /// Sends a `typing.stop` event in this channel to the server.
    ///
    /// - Note: The stop typing event is automatically sent after a few seconds since the last keystroke. Use this method only when it is required to send the event at a different time.
    ///
    /// - Parameter parentMessageId: A message id of the message in a thread the user is replying to.
    ///
    /// - Throws: An error while communicating with the Stream API or missing required capabilities.
    public func stopTyping(parentMessageId: MessageId? = nil) async throws {
        try state.channel?.requireCapability(of: .sendTypingEvents)
        try await typingEventsSender.stopTyping(in: cid, parentMessageId: parentMessageId)
    }
    
    // MARK: - Updating the Channel
    
    /// The update operation updates all of the channel data.
    ///
    /// - Warning: Any data that is present on the channel and is not included in a full update will be **deleted**.
    ///
    /// - Parameters:
    ///   - name: - name: The name of the channel.
    ///   - imageURL: The channel avatar URL.
    ///   - team: The team for the channel.
    ///   - members: A list of members for the channel.
    ///   - invites: A list of users who will get invites.
    ///   - extraData: Extra data for the new channel.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func update(
        name: String?,
        imageURL: URL?,
        team: String?,
        members: Set<UserId> = [],
        invites: Set<UserId> = [],
        extraData: [String: RawJSON] = [:]
    ) async throws {
        try await channelUpdater.update(
            channelPayload: .init(
                cid: cid,
                name: name,
                imageURL: imageURL,
                team: team,
                members: members,
                invites: invites,
                extraData: extraData
            )
        )
    }
    
    /// The update operation updates only specified fields and retain existing channel data.
    ///
    /// A partial update can be used to set and unset specific fields when it is necessary to retain additional
    /// custom data fields on the object (a patch style update).
    ///
    /// - Parameters:
    ///   - name: The name of the channel.
    ///   - imageURL: The channel avatar URL.
    ///   - team: The team for the channel.
    ///   - members: A list of members for the channel.
    ///   - invites: A list of users who will get invites.
    ///   - extraData: Extra data for the channel.
    ///   - unsetProperties: A list of properties to reset.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func updatePartial(
        name: String? = nil,
        imageURL: URL? = nil,
        team: String? = nil,
        members: [UserId] = [],
        invites: [UserId] = [],
        extraData: [String: RawJSON] = [:],
        unsetProperties: [String] = []
    ) async throws {
        try await channelUpdater.updatePartial(
            channelPayload: .init(
                cid: cid,
                name: name,
                imageURL: imageURL,
                team: team,
                members: Set(members),
                invites: Set(invites),
                extraData: extraData
            ),
            unsetProperties: unsetProperties
        )
    }
    
    // MARK: - Uploading and Deleting Files
    
    /// Deletes the file associated with the given URL in the channel.
    ///
    /// - Parameters:
    ///   - url: The URL of the file to be deleted.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func deleteFile(at url: URL) async throws {
        try await channelUpdater.deleteFile(in: cid, url: url.absoluteString)
    }
    
    /// Deletes the image associated with the given URL in the channel.
    ///
    /// - Parameters:
    ///   - url: The URL of the image to be deleted.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func deleteImage(at url: URL) async throws {
        try await channelUpdater.deleteImage(in: cid, url: url.absoluteString)
    }
    
    /// Uploads the given file to CDN and returns an attachment containing the remote URL.
    ///
    /// - Note: The maximum file size is 100 MB.
    /// - Note: This functionality defaults to using the Stream CDN. The used CDN can be configured.
    ///
    /// - Parameters:
    ///   - localFileURL: The URL to a local file.
    ///   - type: The attachment type.
    ///   - progress: The uploading progress handler.
    ///
    /// - Throws: An error while communicating with the Stream API.
    /// - Returns: Returns an uploaded attachment containing the remote url and the attachment metadata.
    public func uploadAttachment(with localFileURL: URL, type: AttachmentType, progress: ((Double) -> Void)? = nil) async throws -> UploadedAttachment {
        try await channelUpdater.uploadFile(type: type, localFileURL: localFileURL, cid: cid, progress: progress)
    }
    
    // MARK: - Watching the Channel
    
    /// Start watching the channel which enables server-side events.
    ///
    /// Watching queries the channel state and returns members, watchers and messages, and notifies the server to start sending events when anything in this channel changes.
    ///
    /// Please refer to [Watching a Channel](https://getstream.io/chat/docs/ios-swift/watch_channel/?language=swift) for additional information.
    ///
    /// - Note: Creating an instance of `Chat` starts watching the channel automatically.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func watch() async throws {
        // Note that watching is started in ChatClient+Chat when channel updater's update is called.
        try await channelUpdater.startWatching(cid: cid, isInRecoveryMode: false)
    }
    
    /// Stop watching the channel which disables server-side events.
    ///
    /// Please refer to [Watching a Channel](https://getstream.io/chat/docs/ios-swift/watch_channel/?language=swift) for additional information.
    ///
    /// - Throws: An error while communicating with the Stream API.
    public func stopWatching() async throws {
        try await channelUpdater.stopWatching(cid: cid)
    }
}

// MARK: - Environment

@available(iOS 13.0, *)
extension Chat {
    struct Environment {
        var chatStateBuilder: (
            _ cid: ChannelId,
            _ channelQuery: ChannelQuery,
            _ messageOrder: MessageOrdering,
            _ database: DatabaseContainer,
            _ eventNotificationCenter: EventNotificationCenter,
            _ paginationState: MessagesPaginationState
        ) -> ChatState = ChatState.init
        
        var messageUpdaterBuilder: (
            _ isLocalStorageEnabled: Bool,
            _ messageRepository: MessageRepository,
            _ database: DatabaseContainer,
            _ apiClient: APIClient
        ) -> MessageUpdater = MessageUpdater.init
        
        var readStateSenderBuilder: (
            _ cid: ChannelId,
            _ channelUpdater: ChannelUpdater,
            _ authenticationRepository: AuthenticationRepository,
            _ messageRepository: MessageRepository
        ) -> ReadStateSender = ReadStateSender.init
        
        var typingEventsSenderBuilder: (
            _ database: DatabaseContainer,
            _ apiClient: APIClient
        ) -> TypingEventsSender = TypingEventsSender.init
    }
}

// MARK: - Chat Client

// TODO: Needs a better solution
private extension ChatClient {
    var attachmentQueueUploader: AttachmentQueueUploader {
        backgroundWorkers.compactMap { $0 as? AttachmentQueueUploader }.first!
    }
    
    var messageEditor: MessageEditor {
        backgroundWorkers.compactMap { $0 as? MessageEditor }.first!
    }

    var messageSender: MessageSender {
        backgroundWorkers.compactMap { $0 as? MessageSender }.first!
    }
}