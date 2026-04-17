;;; k8s-to-puml-new.el --- Generate PlantUML diagrams from Kubernetes YAML -*- lexical-binding: t; -*-

;; Copyright (C) 2024
;;
;; Author: Jeremias
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, kubernetes, plantuml
;; URL: https://github.com/jeremias/k8s-to-puml

;;; Commentary:
;;
;; This package provides a deterministic generator of PlantUML diagrams
;; from Kubernetes YAML manifests. It uses `yaml-ts-mode` (Tree-sitter)
;; to parse the AST and applies a GOFAI (Good Old-Fashioned AI) architecture
;; based on declarative rules to extract facts, infer relations, and render
;; the final diagram.
;;
;; Usage:
;; Open a Kubernetes YAML file (ensure `yaml-ts-mode` is active) and run:
;; M-x k8s-to-puml

;;; Code:

(require 'treesit)
(require 'cl-lib)

;;; Customization

(defgroup k8s-to-puml nil
  "Generate PlantUML diagrams from Kubernetes manifests."
  :group 'tools)

(defcustom k8s-to-puml-plantuml-includes nil
  "PlantUML include directives (e.g., for Kubernetes sprites or custom themes).
If non-nil, this string is injected at the top of the generated diagram.
Example: \"!define k8s https://raw.githubusercontent.com/...\\n!include k8s\""
  :type '(choice (const :tag "None" nil) string)
  :group 'k8s-to-puml)

(defcustom k8s-to-puml-shape-mapping
  '(("Ingress"               . "boundary")
    ("Service"               . "interface")
    ("ConfigMap"             . "collections")
    ("Secret"                . "artifact")
    ("PersistentVolumeClaim" . "database")
    ("PersistentVolume"      . "database")
    ("NetworkPolicy"         . "card")
    ("Role"                  . "file")
    ("RoleBinding"           . "control")
    ("ServiceAccount"        . "artifact"))
  "Mapping of Kubernetes resource kinds to PlantUML shapes.
If a kind is not found in this list, `component` is used as fallback."
  :type '(alist :key-type string :value-type string)
  :group 'k8s-to-puml)

;;; Knowledge Base (Declarative Rules)

(defvar k8s-to-puml-extraction-rules
  '(("RoleBinding" . ((role-ref . ("roleRef" "name"))))
    ("Deployment" . ((name . ("metadata" "name"))
                     (namespace . ("metadata" "namespace"))
                     (match-labels . ("spec" "selector" "matchLabels"))))
    ("Service" . ((name . ("metadata" "name"))
                  (namespace . ("metadata" "namespace"))
                  (selector . ("spec" "selector"))))
    ("Ingress" . ((name . ("metadata" "name"))
                  (namespace . ("metadata" "namespace"))
                  (backends . ("spec" "rules" "*" "http" "paths" "*" "backend" "service" "name")))))
  "Rules to extract fields from YAML AST based on resource kind.
Format: (KIND . ((FIELD-NAME . PATH-LIST) ...))")

(defvar k8s-to-puml-inference-rules
  '((internet . ((predicate . (lambda (facts)
                                (cl-find "Ingress" facts :key (lambda (f) (alist-get 'kind f)) :test #'string=)))
                 (fact . ((kind . "External") (name . "Internet") (puml-id . "internet")))
                 (template . "cloud \"Internet\" as internet\n"))))
  "Rules to infer external elements.
If PREDICATE is true, FACT is added to the knowledge base and TEMPLATE is rendered.")

(defvar k8s-to-puml-relation-rules
  '((internet-ingress
     . ((source . "External")
        (dest . "Ingress")
        (predicate . (lambda (src dst) (string= (alist-get 'name src) "Internet")))
        (template . "%s --> %s : traffic\n")))
    (ingress-service
     . ((source . "Ingress")
        (dest . "Service")
        (predicate . (lambda (src dst)
                       (let ((backends (alist-get 'backends src))
                             (svc-name (alist-get 'name dst)))
                         (member svc-name (flatten-tree backends)))))
        (template . "%s --( %s : routes to\n")))
    (service-deployment
     . ((source . "Service")
        (dest . "Deployment")
        (predicate . (lambda (src dst)
                       (let ((svc-sel (alist-get 'selector src))
                             (dep-sel (alist-get 'match-labels dst)))
                         (and svc-sel dep-sel
                              (cl-every (lambda (pair)
                                          (string= (cdr pair) (alist-get (car pair) dep-sel nil nil #'string=)))
                                        svc-sel)))))
        (template . "%s --(0 %s : selects\n"))))
  "Rules to infer connections between resources.")

;;; Extraction Engine

(defun k8s-to-puml--parse-mapping (node)
  "Convert a block_mapping NODE to an alist."
  (cl-loop for pair in (treesit-node-children node)
           when (string= (treesit-node-type pair) "block_mapping_pair")
           for k-node = (treesit-node-child-by-field-name pair "key")
           for v-node = (treesit-node-child-by-field-name pair "value")
           when (and k-node v-node)
           collect (cons (treesit-node-text k-node t)
                         (treesit-node-text v-node t))))

(defun k8s-to-puml--get-path (node path)
  "Traverse NODE following PATH (list of strings).
If a path element is '*', returns a list of all sequence items.
If path is exhausted and node is a mapping, returns an alist."
  (if (null path)
      (let ((type (treesit-node-type node)))
        (cond
         ((string= type "block_mapping") (k8s-to-puml--parse-mapping node))
         ((string= type "flow_node") (treesit-node-text node t))
         ((string= type "block_node")
          (let ((child (cl-find-if-not (lambda (n) (member (treesit-node-type n) '("-" "---")))
                                       (treesit-node-children node))))
            (when child (k8s-to-puml--get-path child nil))))
         (t (treesit-node-text node t))))
    (let ((key (car path))
          (rest (cdr path))
          (type (treesit-node-type node)))
      (cond
       ((member type '("document" "block_node" "block_sequence_item"))
        ;; Fix: Ignore punctuation nodes like "-" or "---" when unwrapping
        (let ((child (cl-find-if-not (lambda (n) (member (treesit-node-type n) '("-" "---")))
                                     (treesit-node-children node))))
          (when child (k8s-to-puml--get-path child path))))
       ((string= type "block_mapping")
        (let ((child (cl-loop for pair in (treesit-node-children node)
                              when (string= (treesit-node-type pair) "block_mapping_pair")
                              for k-node = (treesit-node-child-by-field-name pair "key")
                              if (string= (treesit-node-text k-node t) key)
                              return (treesit-node-child-by-field-name pair "value"))))
          (when child (k8s-to-puml--get-path child rest))))
       ((string= type "block_sequence")
        (if (string= key "*")
            (delq nil (mapcar (lambda (item)
                                (when (string= (treesit-node-type item) "block_sequence_item")
                                  (k8s-to-puml--get-path item rest)))
                              (treesit-node-children node)))
          nil))
       (t nil)))))

(defun k8s-to-puml--extract-facts (root-node)
  "Extract facts (alists) from YAML ROOT-NODE based on extraction rules."
  (let ((facts nil))
    (dolist (doc (treesit-node-children root-node))
      (when (string= (treesit-node-type doc) "document")
        (let* ((body (cl-find "block_node" (treesit-node-children doc) :key #'treesit-node-type :test #'string=))
               (mapping (when body (cl-find "block_mapping" (treesit-node-children body) :key #'treesit-node-type :test #'string=)))
               (kind (when mapping (k8s-to-puml--get-path mapping '("kind")))))
          (when kind
            (let ((rules (alist-get kind k8s-to-puml-extraction-rules nil nil #'string=))
                  (fact `((kind . ,kind))))
              ;; Always extract name and namespace as fallback
              (push `(name . ,(k8s-to-puml--get-path mapping '("metadata" "name"))) fact)
              (push `(namespace . ,(or (k8s-to-puml--get-path mapping '("metadata" "namespace")) "default")) fact)
              ;; Apply specific rules
              (dolist (rule rules)
                (let ((field (car rule))
                      (path (cdr rule)))
                  (unless (assq field fact)
                    (push (cons field (k8s-to-puml--get-path mapping path)) fact))))
              ;; Generate PUML ID
              (push `(puml-id . ,(format "%s_%s"
                                         (downcase kind)
                                         (replace-regexp-in-string "[^a-zA-Z0-9]" "_" (alist-get 'name fact))))
                    fact)
              (push fact facts))))))
    (nreverse facts)))

;;; Inference & Rendering Engine

(defun k8s-to-puml--transform-rolegroups (facts)
  "Merge RoleBindings and Roles in 'RoleGroup'. Keep orphan kinds."
  (let ((new-facts nil)
        (used-roles nil))
    ;; 1. Makes the groups thourgh Bindings
    (dolist (fact facts)
      (when (string= (alist-get 'kind fact) "RoleBinding")
        (let* ((ref (alist-get 'role-ref fact))
               (role (cl-find-if (lambda (f) 
                                   (and (string= (alist-get 'kind f) "Role") 
                                        (string= (alist-get 'name f) ref))) 
                                 facts)))
          (when role (push (alist-get 'name role) used-roles))
          (push `((kind . "RoleGroup")
                  (namespace . ,(alist-get 'namespace fact))
                  (puml-id . ,(alist-get 'puml-id fact))
                  (rb-name . ,(alist-get 'name fact))
                  (role-name . ,(if role (alist-get 'name role) ref)))
                new-facts))))
    ;; 2. Return groups and facts (except previous Bindings and Roles)
    (append new-facts
            (cl-remove-if (lambda (f)
                            (or (string= (alist-get 'kind f) "RoleBinding")
                                (and (string= (alist-get 'kind f) "Role")
                                     (member (alist-get 'name f) used-roles))))
                          facts))))

(defun k8s-to-puml--generate-puml (facts)
  "Generate PlantUML string from extracted FACTS."
  (let ((puml (list "@startuml\nskinparam componentStyle uml2\n"))
        (namespaces (make-hash-table :test 'equal))
        (inferred-facts nil))

    (when k8s-to-puml-plantuml-includes
      (push (concat k8s-to-puml-plantuml-includes "\n") puml))

    ;; 1. Infer External Elements (Rendered outside the cluster)
    (dolist (rule k8s-to-puml-inference-rules)
      (let* ((def (cdr rule))
             (pred (alist-get 'predicate def))
             (fact (alist-get 'fact def))
             (tmpl (alist-get 'template def)))
        (when (funcall pred facts)
          (push fact inferred-facts)
          (push tmpl puml))))

    (setq facts (append inferred-facts facts))
    (setq facts (k8s-to-puml--transform-rolegroups facts))

    ;; 2. Group by Namespace (excluding Externals)
    (dolist (fact facts)
      (let ((ns (alist-get 'namespace fact)))
        (when ns
          (puthash ns (cons fact (gethash ns namespaces)) namespaces))))

    ;; 3. Render Cluster and Namespaces
    (push "node \"Kubernetes Cluster\" {\n" puml)
    (maphash (lambda (ns ns-facts)
               (push (format "  package \"Namespace: %s\" {\n" ns) puml)
               (dolist (fact ns-facts)
                 (let* ((kind (alist-get 'kind fact))
                        (name (alist-get 'name fact))
                        (id (alist-get 'puml-id fact)))
                   (if (string= kind "RoleGroup")
                       (push (format "    folder %s [\n\t[RoleBinding]\n\t----\n\t%s\n\t====\n\t[Role]\n\t----\n\t%s\n    ]\n"
                                     id (alist-get 'rb-name fact) (alist-get 'role-name fact))
                             puml)
                     (let ((shape (or (cdr (assoc kind k8s-to-puml-shape-mapping)) "component")))
                       (push (format "    %s \"[%s]\\n%s\" as %s\n" shape kind name id) puml)))))
               (push "  }\n" puml))
             namespaces)
    (push "}\n" puml)

    ;; 4. Infer and Render Relations (Cartesian Product)
    (dolist (src facts)
      (dolist (dst facts)
        (unless (eq src dst)
          (dolist (rule k8s-to-puml-relation-rules)
            (let* ((def (cdr rule))
                   (r-src (alist-get 'source def))
                   (r-dst (alist-get 'dest def))
                   (pred (alist-get 'predicate def))
                   (tmpl (alist-get 'template def)))
              (when (and (string= (alist-get 'kind src) r-src)
                         (string= (alist-get 'kind dst) r-dst)
                         (funcall pred src dst))
                (push (format tmpl (alist-get 'puml-id src) (alist-get 'puml-id dst)) puml)))))))

    (push "@enduml\n" puml)
    (apply #'concat (nreverse puml))))

;;; Interactive Command

;;;###autoload
(defun k8s-to-puml ()
  "Generate a PlantUML diagram from the current Kubernetes YAML buffer."
  (interactive)
  (unless (derived-mode-p 'yaml-ts-mode)
    (user-error "Buffer must be in yaml-ts-mode"))
  (let* ((root (treesit-buffer-root-node))
         (facts (k8s-to-puml--extract-facts root))
         (puml-str (k8s-to-puml--generate-puml facts))
         (buf (get-buffer-create "*k8s-to-puml-draft-diagram*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert puml-str)
      (when (fboundp 'plantuml-mode)
        (plantuml-mode)))
    (display-buffer buf)
    (message "PlantUML draft generated successfully!")))

(provide 'k8s-to-puml)
;;; k8s-to-puml-new.el ends here
