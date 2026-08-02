(library (soda editor jump-graph)
  (export make-jump-node
          jump-node?
          jump-node-id
          jump-node-resource
          jump-node-buffer-id
          jump-node-revision
          jump-node-start
          jump-node-end
          jump-node-excerpt
          jump-node-language-context
          jump-node-last-visit
          make-jump-edge
          jump-edge?
          jump-edge-from
          jump-edge-to
          jump-edge-kind
          jump-edge-timestamp
          make-jump-graph
          jump-graph?
          jump-graph-nodes
          jump-graph-edges
          jump-graph-limit
          jump-graph-record!
          jump-graph-replace!
          jump-graph-attach-buffer!
          jump-graph-detach-buffer!
          jump-graph-close!)
  (import (rnrs)
          (soda editor contract)
          (soda document)
          (soda editor buffer)
          (soda editor location))

  (define-record-type
    (jump-node %make-jump-node jump-node?)
    (fields id
            resource
            (mutable buffer-id jump-node-buffer-id jump-node-buffer-id-set!)
            revision
            (mutable start %jump-node-start jump-node-start-set!)
            end
            excerpt
            language-context
            (mutable last-visit jump-node-last-visit jump-node-last-visit-set!)
            (mutable document jump-node-document jump-node-document-set!)
            (mutable anchor jump-node-anchor jump-node-anchor-set!)))

  (define-record-type jump-edge
    (fields from to kind timestamp))

  (define-record-type
    (jump-graph %make-jump-graph jump-graph?)
    (fields
      (mutable nodes jump-graph-nodes jump-graph-nodes-set!)
      (mutable edges jump-graph-edges jump-graph-edges-set!)
      (immutable limit jump-graph-limit)
      (mutable next-node-id jump-graph-next-node-id jump-graph-next-node-id-set!)
      (mutable clock jump-graph-clock jump-graph-clock-set!)))

  (define (make-jump-node
            id resource buffer-id revision start end excerpt language-context
            last-visit)
    (unless
      (and
        (exact-positive-integer? id)
        (string? resource)
        (or (not buffer-id) (exact-non-negative-integer? buffer-id))
        (exact-non-negative-integer? revision)
        (exact-non-negative-integer? start)
        (exact-non-negative-integer? end)
        (<= start end)
        (or (not excerpt) (string? excerpt))
        (exact-non-negative-integer? last-visit))
      (assertion-violation
        'make-jump-node
        "invalid JumpNode"
        id resource buffer-id revision start end excerpt last-visit))
    (%make-jump-node
      id resource buffer-id revision start end excerpt language-context
      last-visit #f #f))

  (define (jump-node-start node)
    (unless (jump-node? node)
      (assertion-violation 'jump-node-start "expected a JumpNode" node))
    (if (and (jump-node-document node) (jump-node-anchor node))
        (document-anchor-offset
          (jump-node-document node)
          (jump-node-anchor node))
        (%jump-node-start node)))

  (define (make-jump-graph . maybe-limit)
    (let ([limit (if (null? maybe-limit) 512 (car maybe-limit))])
      (unless (and (exact-positive-integer? limit)
                   (or (null? maybe-limit) (null? (cdr maybe-limit))))
        (assertion-violation
          'make-jump-graph
          "limit must be a positive exact integer"
          maybe-limit))
      (%make-jump-graph '() '() limit 1 0)))

  (define (require-graph who graph)
    (unless (jump-graph? graph)
      (assertion-violation who "expected a JumpGraph" graph)))

  (define (stable-resource? value)
    (and
      (string? value)
      (positive? (string-length value))
      (not (char=? (string-ref value 0) #\*))))

  (define (same-node-location? node item)
    (and
      (string=? (jump-node-resource node) (location-item-resource item))
      (= (div (jump-node-start node) 16)
         (div (location-item-start item) 16))
      (equal? (jump-node-language-context node)
              (location-item-language-context item))))

  (define (graph-node-for-item! graph item timestamp)
    (let ([resource (location-item-resource item)])
      (and
        (stable-resource? resource)
        (let ([existing
                (find
                  (lambda (node) (same-node-location? node item))
                  (jump-graph-nodes graph))])
          (if existing
              (begin
                (jump-node-last-visit-set! existing timestamp)
                existing)
              (let* ([id (jump-graph-next-node-id graph)]
                     [node
                       (make-jump-node
                         id
                         resource
                         (location-item-buffer-id item)
                         (location-item-revision item)
                         (location-item-start item)
                         (location-item-end item)
                         (location-item-excerpt item)
                         (location-item-language-context item)
                         timestamp)])
                (jump-graph-next-node-id-set! graph (+ id 1))
                (jump-graph-nodes-set!
                  graph
                  (append (jump-graph-nodes graph) (list node)))
                node))))))

  (define (manual-node-ids graph)
    (fold-left
      (lambda (ids edge)
        (if (eq? (jump-edge-kind edge) 'manual)
            (cons (jump-edge-from edge) (cons (jump-edge-to edge) ids))
            ids))
      '()
      (jump-graph-edges graph)))

  (define (oldest-evictable-node graph)
    (let ([manual (manual-node-ids graph)])
      (fold-left
        (lambda (oldest node)
          (if
            (or
              (memv (jump-node-id node) manual)
              (and oldest
                   (<= (jump-node-last-visit oldest)
                       (jump-node-last-visit node))))
            oldest
            node))
        #f
        (jump-graph-nodes graph))))

  (define (release-node-anchor! node)
    (when (and (jump-node-document node) (jump-node-anchor node))
      (document-remove-anchor!
        (jump-node-document node)
        (jump-node-anchor node)))
    (jump-node-document-set! node #f)
    (jump-node-anchor-set! node #f)
    (jump-node-buffer-id-set! node #f))

  (define (trim-graph! graph)
    (let loop ()
      (when (> (length (jump-graph-nodes graph)) (jump-graph-limit graph))
        (let ([node (oldest-evictable-node graph)])
          (when node
            (let ([id (jump-node-id node)])
              (release-node-anchor! node)
              (jump-graph-nodes-set!
                graph
                (filter
                  (lambda (candidate) (not (= (jump-node-id candidate) id)))
                  (jump-graph-nodes graph)))
              (jump-graph-edges-set!
                graph
                (filter
                  (lambda (edge)
                    (and
                      (not (= (jump-edge-from edge) id))
                      (not (= (jump-edge-to edge) id))))
                  (jump-graph-edges graph)))
              (loop)))))))

  (define (jump-graph-record! graph source target kind)
    (require-graph 'jump-graph-record! graph)
    (unless (and (location-item? source)
                 (location-item? target)
                 (symbol? kind))
      (assertion-violation
        'jump-graph-record!
        "expected source and target LocationItems and a kind"
        source target kind))
    (let ([timestamp (+ (jump-graph-clock graph) 1)])
      (jump-graph-clock-set! graph timestamp)
      (let ([from (graph-node-for-item! graph source timestamp)]
            [to (graph-node-for-item! graph target timestamp)])
        (and
          from
          to
          (let ([edge
                  (make-jump-edge
                    (jump-node-id from)
                    (jump-node-id to)
                    kind
                    timestamp)])
            (jump-graph-edges-set!
              graph
              (append (jump-graph-edges graph) (list edge)))
            (trim-graph! graph)
            edge)))))

  (define (jump-graph-replace! graph nodes edges)
    (require-graph 'jump-graph-replace! graph)
    (unless (and (list? nodes) (for-all jump-node? nodes)
                 (list? edges) (for-all jump-edge? edges))
      (assertion-violation
        'jump-graph-replace!
        "expected JumpNode and JumpEdge lists"
        nodes edges))
    (for-each release-node-anchor! (jump-graph-nodes graph))
    (jump-graph-nodes-set! graph nodes)
    (jump-graph-edges-set! graph edges)
    (jump-graph-next-node-id-set!
      graph
      (+ 1
         (fold-left
           (lambda (maximum node) (max maximum (jump-node-id node)))
           0
           nodes)))
    (jump-graph-clock-set!
      graph
      (fold-left
        (lambda (maximum edge) (max maximum (jump-edge-timestamp edge)))
        0
        edges))
    (trim-graph! graph)
    graph)

  (define (jump-graph-attach-buffer! graph buffer)
    (require-graph 'jump-graph-attach-buffer! graph)
    (unless (buffer? buffer)
      (assertion-violation
        'jump-graph-attach-buffer!
        "expected a Buffer"
        buffer))
    (let ([resource (or (buffer-file-path buffer) (buffer-resource buffer))]
          [document (buffer-document buffer)]
          [end (buffer-byte-size buffer)])
      (when resource
        (for-each
          (lambda (node)
            (when
              (and
                (string=? resource (jump-node-resource node))
                (not (jump-node-anchor node)))
              (jump-node-buffer-id-set! node (buffer-id buffer))
              (jump-node-document-set! node document)
              (jump-node-anchor-set!
                node
                (document-create-anchor!
                  document
                  (min (%jump-node-start node) end)
                  anchor-after-insertion))))
          (jump-graph-nodes graph))))
    graph)

  (define (jump-graph-detach-buffer! graph buffer-id)
    (require-graph 'jump-graph-detach-buffer! graph)
    (for-each
      (lambda (node)
        (when (and (jump-node-buffer-id node)
                   (= (jump-node-buffer-id node) buffer-id))
          (when (and (jump-node-document node) (jump-node-anchor node))
            (jump-node-start-set! node (jump-node-start node)))
          (release-node-anchor! node)))
      (jump-graph-nodes graph))
    graph)

  (define (jump-graph-close! graph)
    (require-graph 'jump-graph-close! graph)
    (for-each
      (lambda (node)
        (release-node-anchor! node))
      (jump-graph-nodes graph))
    (jump-graph-nodes-set! graph '())
    (jump-graph-edges-set! graph '())
    graph)
)
