;; sparktide-core
;; 
;; This contract manages digital moodboards as unique NFTs on the Stacks blockchain.
;; It handles creation, ownership, collaboration permissions, and content management
;; for the SparkTide creative collaboration platform.
;;
;; The contract enables creators to:
;; - Create and own moodboards as NFTs
;; - Set collaboration permissions (public, private, invited-only)
;; - Manage contributors and their access levels
;; - Track versions as moodboards evolve
;; - Monetize their creations if desired
;;
;; All operations enforce proper attribution and respect permission settings.

;; Error Constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-MOODBOARD-NOT-FOUND (err u101))
(define-constant ERR-INVALID-PERMISSION-TYPE (err u102))
(define-constant ERR-ALREADY-EXISTS (err u103))
(define-constant ERR-NOT-COLLABORATOR (err u104))
(define-constant ERR-INVALID-STATUS (err u105))
(define-constant ERR-UNAUTHORIZED-CONTRIBUTOR (err u106))
(define-constant ERR-INVALID-CONTENT-TYPE (err u107))
(define-constant ERR-INVALID-VERSION (err u108))
(define-constant ERR-MONETIZATION-DISABLED (err u109))
(define-constant ERR-VOTE-ALREADY-CAST (err u110))
(define-constant ERR-PROPOSAL-EXPIRED (err u111))

;; Permission Types
(define-constant PERMISSION-PUBLIC u1)
(define-constant PERMISSION-PRIVATE u2)
(define-constant PERMISSION-INVITED-ONLY u3)

;; Content Types
(define-constant CONTENT-TYPE-IMAGE u1)
(define-constant CONTENT-TYPE-COLOR u2)
(define-constant CONTENT-TYPE-TEXT u3)
(define-constant CONTENT-TYPE-TEXTURE u4)

;; Moodboard Status
(define-constant STATUS-ACTIVE u1)
(define-constant STATUS-ARCHIVED u2)

;; Data Maps and Variables

;; Tracks the next available moodboard ID
(define-data-var next-moodboard-id uint u1)

;; Moodboard metadata storage
(define-map moodboards
  uint  ;; moodboard-id
  {
    creator: principal,
    title: (string-ascii 100),
    description: (string-utf8 500),
    permission-type: uint,
    status: uint,
    created-at: uint,
    updated-at: uint,
    version: uint,
    monetization-enabled: bool
  }
)

;; Stores collaborator permissions for each moodboard
(define-map collaborators
  { moodboard-id: uint, user: principal }
  {
    can-view: bool,
    can-edit: bool,
    can-invite: bool,
    added-by: principal,
    added-at: uint
  }
)

;; Tracks content items within each moodboard
(define-map moodboard-content
  { moodboard-id: uint, content-id: uint }
  {
    content-type: uint,
    content-url: (string-ascii 255),
    creator: principal,
    added-by: principal,
    added-at: uint,
    metadata: (string-utf8 500)
  }
)

;; Tracks the next content ID for each moodboard
(define-map next-content-id
  uint  ;; moodboard-id
  uint  ;; next-content-id
)

;; Tracks version history of moodboards
(define-map moodboard-versions
  { moodboard-id: uint, version: uint }
  {
    updated-at: uint,
    updated-by: principal,
    change-description: (string-utf8 255)
  }
)

;; Governance proposals
(define-map governance-proposals
  uint  ;; proposal-id
  {
    title: (string-ascii 100),
    description: (string-utf8 1000),
    creator: principal,
    created-at: uint,
    expires-at: uint,
    executed: bool
  }
)

;; Tracks votes on governance proposals
(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  { vote: bool }
)

;; Tracks vote tallies for each proposal
(define-map proposal-vote-counts
  uint  ;; proposal-id
  { yes-votes: uint, no-votes: uint }
)

;; Tracks the next available proposal ID
(define-data-var next-proposal-id uint u1)

;; Private Functions

;; Check if a user is the creator of a moodboard
(define-private (is-moodboard-creator (moodboard-id uint) (user principal))
  (match (map-get? moodboards moodboard-id)
    moodboard (is-eq (get creator moodboard) user)
    false
  )
)

;; Check if a user has specific collaborator permissions
(define-private (has-permission (moodboard-id uint) (user principal) (permission-key (string-ascii 10)))
  (match (map-get? collaborators { moodboard-id: moodboard-id, user: user })
    collaborator 
    (if (is-eq permission-key "view")
        (get can-view collaborator)
        (if (is-eq permission-key "edit")
            (get can-edit collaborator)
            (if (is-eq permission-key "invite")
                (get can-invite collaborator)
                false
            )
        )
    )
    false
  )
)

;; Check if user can view a moodboard based on permissions
(define-private (can-view-moodboard (moodboard-id uint) (user principal))
  (match (map-get? moodboards moodboard-id)
    moodboard
    (let ((permission-type (get permission-type moodboard)))
      (or 
        (is-eq (get creator moodboard) user)
        (is-eq permission-type PERMISSION-PUBLIC)
        (has-permission moodboard-id user "view")
      )
    )
    false
  )
)

;; Check if user can edit a moodboard based on permissions
(define-private (can-edit-moodboard (moodboard-id uint) (user principal))
  (or
    (is-moodboard-creator moodboard-id user)
    (has-permission moodboard-id user "edit")
  )
)

;; Increment version number for a moodboard
(define-private (increment-moodboard-version (moodboard-id uint) (change-description (string-utf8 255)))
  (match (map-get? moodboards moodboard-id)
    moodboard
    (let ((current-version (get version moodboard))
          (next-version (+ (get version moodboard) u1))
          (block-height (unwrap-panic (get-block-info? time u0))))
      
      ;; Add version history entry
      (map-set moodboard-versions
        { moodboard-id: moodboard-id, version: current-version }
        {
          updated-at: block-height,
          updated-by: tx-sender,
          change-description: change-description
        }
      )
      
      ;; Update moodboard with new version and timestamp
      (map-set moodboards
        moodboard-id
        (merge moodboard {
          version: next-version,
          updated-at: block-height
        })
      )
      
      (ok next-version)
    )
    ERR-MOODBOARD-NOT-FOUND
  )
)

;; Initialize a new content ID counter for a moodboard
(define-private (init-content-id-counter (moodboard-id uint))
  (map-set next-content-id moodboard-id u1)
)

;; Get the next content ID for a moodboard
(define-private (get-next-content-id (moodboard-id uint))
  (match (map-get? next-content-id moodboard-id)
    next-id 
    (begin
      (map-set next-content-id moodboard-id (+ next-id u1))
      next-id
    )
    u1
  )
)

;; Public Functions

;; Create a new moodboard
(define-public (create-moodboard 
                (title (string-ascii 100)) 
                (description (string-utf8 500)) 
                (permission-type uint))
  (let ((moodboard-id (var-get next-moodboard-id))
        (block-height (unwrap-panic (get-block-info? time u0))))
    
    ;; Validate permission type
    (asserts! (or 
                (is-eq permission-type PERMISSION-PUBLIC)
                (is-eq permission-type PERMISSION-PRIVATE)
                (is-eq permission-type PERMISSION-INVITED-ONLY))
              ERR-INVALID-PERMISSION-TYPE)
    
    ;; Store moodboard data
    (map-set moodboards
      moodboard-id
      {
        creator: tx-sender,
        title: title,
        description: description,
        permission-type: permission-type,
        status: STATUS-ACTIVE,
        created-at: block-height,
        updated-at: block-height,
        version: u1,
        monetization-enabled: false
      }
    )
    
    ;; Initialize content ID counter
    (init-content-id-counter moodboard-id)
    
    ;; Add creator as a collaborator with all permissions
    (map-set collaborators
      { moodboard-id: moodboard-id, user: tx-sender }
      {
        can-view: true,
        can-edit: true,
        can-invite: true,
        added-by: tx-sender,
        added-at: block-height
      }
    )
    
    ;; Increment moodboard ID counter
    (var-set next-moodboard-id (+ moodboard-id u1))
    
    ;; Record initial version
    (map-set moodboard-versions
      { moodboard-id: moodboard-id, version: u1 }
      {
        updated-at: block-height,
        updated-by: tx-sender,
        change-description: "Initial creation"
      }
    )
    
    (ok moodboard-id)
  )
)

;; Update moodboard metadata
(define-public (update-moodboard 
                (moodboard-id uint)
                (title (string-ascii 100))
                (description (string-utf8 500))
                (permission-type uint))
  (let ((block-height (unwrap-panic (get-block-info? time u0))))
    
    ;; Check authorization
    (asserts! (is-moodboard-creator moodboard-id tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Verify moodboard exists
    (match (map-get? moodboards moodboard-id)
      moodboard
      (begin
        ;; Validate permission type
        (asserts! (or 
                    (is-eq permission-type PERMISSION-PUBLIC)
                    (is-eq permission-type PERMISSION-PRIVATE)
                    (is-eq permission-type PERMISSION-INVITED-ONLY))
                  ERR-INVALID-PERMISSION-TYPE)
        
        ;; Update moodboard metadata
        (map-set moodboards
          moodboard-id
          (merge moodboard {
            title: title,
            description: description,
            permission-type: permission-type,
            updated-at: block-height
          })
        )
        
        ;; Update version
        (increment-moodboard-version moodboard-id "Updated moodboard metadata")
      )
      ERR-MOODBOARD-NOT-FOUND
    )
  )
)

;; Add a collaborator to a moodboard
(define-public (add-collaborator 
                (moodboard-id uint)
                (collaborator principal)
                (can-view bool)
                (can-edit bool)
                (can-invite bool))
  (let ((block-height (unwrap-panic (get-block-info? time u0))))
    
    ;; Check if sender is either the creator or has invite permissions
    (asserts! (or 
                (is-moodboard-creator moodboard-id tx-sender)
                (has-permission moodboard-id tx-sender "invite"))
              ERR-NOT-AUTHORIZED)
    
    ;; Check if moodboard exists
    (asserts! (map-get? moodboards moodboard-id) ERR-MOODBOARD-NOT-FOUND)
    
    ;; Add collaborator with specified permissions
    (map-set collaborators
      { moodboard-id: moodboard-id, user: collaborator }
      {
        can-view: can-view,
        can-edit: can-edit,
        can-invite: can-invite,
        added-by: tx-sender,
        added-at: block-height
      }
    )
    
    (ok true)
  )
)

;; Remove a collaborator from a moodboard
(define-public (remove-collaborator (moodboard-id uint) (collaborator principal))
  ;; Check if sender is the creator
  (asserts! (is-moodboard-creator moodboard-id tx-sender) ERR-NOT-AUTHORIZED)
  
  ;; Check if moodboard exists
  (asserts! (map-get? moodboards moodboard-id) ERR-MOODBOARD-NOT-FOUND)
  
  ;; Remove collaborator
  (map-delete collaborators { moodboard-id: moodboard-id, user: collaborator })
  
  (ok true)
)

;; Add content to a moodboard
(define-public (add-content 
                (moodboard-id uint)
                (content-type uint)
                (content-url (string-ascii 255))
                (metadata (string-utf8 500)))
  (let ((block-height (unwrap-panic (get-block-info? time u0)))
        (content-id (get-next-content-id moodboard-id)))
    
    ;; Check if user can edit the moodboard
    (asserts! (can-edit-moodboard moodboard-id tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Check if moodboard exists
    (asserts! (map-get? moodboards moodboard-id) ERR-MOODBOARD-NOT-FOUND)
    
    ;; Validate content type
    (asserts! (or
                (is-eq content-type CONTENT-TYPE-IMAGE)
                (is-eq content-type CONTENT-TYPE-COLOR)
                (is-eq content-type CONTENT-TYPE-TEXT)
                (is-eq content-type CONTENT-TYPE-TEXTURE))
              ERR-INVALID-CONTENT-TYPE)
    
    ;; Add content
    (map-set moodboard-content
      { moodboard-id: moodboard-id, content-id: content-id }
      {
        content-type: content-type,
        content-url: content-url,
        creator: tx-sender,
        added-by: tx-sender,
        added-at: block-height,
        metadata: metadata
      }
    )
    
    ;; Update moodboard version
    (increment-moodboard-version moodboard-id "Added new content")
    
    (ok content-id)
  )
)

;; Remove content from a moodboard
(define-public (remove-content (moodboard-id uint) (content-id uint))
  ;; Check if user can edit the moodboard
  (asserts! (can-edit-moodboard moodboard-id tx-sender) ERR-NOT-AUTHORIZED)
  
  ;; Check if moodboard exists
  (asserts! (map-get? moodboards moodboard-id) ERR-MOODBOARD-NOT-FOUND)
  
  ;; Check if content exists
  (asserts! (map-get? moodboard-content { moodboard-id: moodboard-id, content-id: content-id }) ERR-MOODBOARD-NOT-FOUND)
  
  ;; Remove content
  (map-delete moodboard-content { moodboard-id: moodboard-id, content-id: content-id })
  
  ;; Update moodboard version
  (increment-moodboard-version moodboard-id "Removed content")
  
  (ok true)
)

;; Archive a moodboard
(define-public (archive-moodboard (moodboard-id uint))
  ;; Check if user is the creator
  (asserts! (is-moodboard-creator moodboard-id tx-sender) ERR-NOT-AUTHORIZED)
  
  ;; Update moodboard status
  (match (map-get? moodboards moodboard-id)
    moodboard 
    (begin
      (map-set moodboards
        moodboard-id
        (merge moodboard { 
          status: STATUS-ARCHIVED,
          updated-at: (unwrap-panic (get-block-info? time u0))
        })
      )
      (ok true)
    )
    ERR-MOODBOARD-NOT-FOUND
  )
)

;; Reactivate an archived moodboard
(define-public (reactivate-moodboard (moodboard-id uint))
  ;; Check if user is the creator
  (asserts! (is-moodboard-creator moodboard-id tx-sender) ERR-NOT-AUTHORIZED)
  
  ;; Update moodboard status
  (match (map-get? moodboards moodboard-id)
    moodboard 
    (begin
      (asserts! (is-eq (get status moodboard) STATUS-ARCHIVED) ERR-INVALID-STATUS)
      
      (map-set moodboards
        moodboard-id
        (merge moodboard { 
          status: STATUS-ACTIVE,
          updated-at: (unwrap-panic (get-block-info? time u0))
        })
      )
      (ok true)
    )
    ERR-MOODBOARD-NOT-FOUND
  )
)

;; Enable/disable monetization for a moodboard
(define-public (toggle-monetization (moodboard-id uint) (enabled bool))
  ;; Check if user is the creator
  (asserts! (is-moodboard-creator moodboard-id tx-sender) ERR-NOT-AUTHORIZED)
  
  ;; Update monetization setting
  (match (map-get? moodboards moodboard-id)
    moodboard 
    (begin
      (map-set moodboards
        moodboard-id
        (merge moodboard { 
          monetization-enabled: enabled,
          updated-at: (unwrap-panic (get-block-info? time u0))
        })
      )
      (ok true)
    )
    ERR-MOODBOARD-NOT-FOUND
  )
)

;; Create a governance proposal
(define-public (create-proposal 
                (title (string-ascii 100))
                (description (string-utf8 1000))
                (duration uint))
  (let ((proposal-id (var-get next-proposal-id))
        (block-height (unwrap-panic (get-block-info? time u0))))
    
    ;; Store proposal data
    (map-set governance-proposals
      proposal-id
      {
        title: title,
        description: description,
        creator: tx-sender,
        created-at: block-height,
        expires-at: (+ block-height duration),
        executed: false
      }
    )
    
    ;; Initialize vote counts
    (map-set proposal-vote-counts
      proposal-id
      {
        yes-votes: u0,
        no-votes: u0
      }
    )
    
    ;; Increment proposal ID counter
    (var-set next-proposal-id (+ proposal-id u1))
    
    (ok proposal-id)
  )
)

;; Vote on a governance proposal
(define-public (vote-on-proposal (proposal-id uint) (vote bool))
  (let ((block-height (unwrap-panic (get-block-info? time u0))))
    
    ;; Check if proposal exists
    (match (map-get? governance-proposals proposal-id)
      proposal
      (begin
        ;; Check if proposal hasn't expired
        (asserts! (< block-height (get expires-at proposal)) ERR-PROPOSAL-EXPIRED)
        
        ;; Check if user hasn't already voted
        (asserts! (is-none (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender })) ERR-VOTE-ALREADY-CAST)
        
        ;; Record the vote
        (map-set proposal-votes
          { proposal-id: proposal-id, voter: tx-sender }
          { vote: vote }
        )
        
        ;; Update vote counts
        (match (map-get? proposal-vote-counts proposal-id)
          counts
          (if vote
              (map-set proposal-vote-counts
                proposal-id
                (merge counts { yes-votes: (+ (get yes-votes counts) u1) })
              )
              (map-set proposal-vote-counts
                proposal-id
                (merge counts { no-votes: (+ (get no-votes counts) u1) })
              )
          )
          (err u0)  ;; Should never happen as counts are initialized at proposal creation
        )
        
        (ok true)
      )
      ERR-MOODBOARD-NOT-FOUND
    )
  )
)

;; Read-Only Functions

;; Get moodboard details
(define-read-only (get-moodboard (moodboard-id uint))
  (match (map-get? moodboards moodboard-id)
    moodboard 
    (if (can-view-moodboard moodboard-id tx-sender)
        (ok moodboard)
        ERR-NOT-AUTHORIZED
    )
    ERR-MOODBOARD-NOT-FOUND
  )
)

;; Get collaborator details
(define-read-only (get-collaborator (moodboard-id uint) (user principal))
  (match (map-get? collaborators { moodboard-id: moodboard-id, user: user })
    collaborator (ok collaborator)
    (err u0)
  )
)

;; Check if user has permission to view a moodboard
(define-read-only (check-view-permission (moodboard-id uint) (user principal))
  (ok (can-view-moodboard moodboard-id user))
)

;; Check if user has permission to edit a moodboard
(define-read-only (check-edit-permission (moodboard-id uint) (user principal))
  (ok (can-edit-moodboard moodboard-id user))
)

;; Get content details
(define-read-only (get-content (moodboard-id uint) (content-id uint))
  (match (map-get? moodboard-content { moodboard-id: moodboard-id, content-id: content-id })
    content 
    (if (can-view-moodboard moodboard-id tx-sender)
        (ok content)
        ERR-NOT-AUTHORIZED
    )
    (err u0)
  )
)

;; Get version history
(define-read-only (get-version-history (moodboard-id uint) (version uint))
  (match (map-get? moodboard-versions { moodboard-id: moodboard-id, version: version })
    version-history 
    (if (can-view-moodboard moodboard-id tx-sender)
        (ok version-history)
        ERR-NOT-AUTHORIZED
    )
    (err u0)
  )
)

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (match (map-get? governance-proposals proposal-id)
    proposal (ok proposal)
    (err u0)
  )
)

;; Get proposal vote counts
(define-read-only (get-proposal-votes (proposal-id uint))
  (match (map-get? proposal-vote-counts proposal-id)
    counts (ok counts)
    (err u0)
  )
)

;; Check if a user has voted on a proposal
(define-read-only (has-voted (proposal-id uint) (user principal))
  (is-some (map-get? proposal-votes { proposal-id: proposal-id, voter: user }))
)