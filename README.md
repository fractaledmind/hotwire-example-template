# Hotwire: Action Text-powered mentions

[![Deploy to Heroku](https://www.herokucdn.com/deploy/button.png)][heroku-deploy-app]

[heroku-deploy-app]: https://heroku.com/deploy?template=https://github.com/thoughtbot/hotwire-example-template/tree/hotwire-example-action-text-mentions

[Action Text][] is one the more powerful frameworks that Rails provides
out-of-the-box. Unfortunately, its ambition seems to outpace its
popularity.

In addition to its rich text editing capabilities, Action Text's most
well-known features is its built-in support file attachments through its
integration with Active Storage.

The framework's immense potential is rooted in its ability to attach
custom entities using the same mechanism as Active Storage files. Once
attached, Action Text uses the server's Action View-powered templating
to transform those entities into HTML.

For the sake of demonstration, let's attach `User` records to Action
Text content whenever their `username` is "@"-mentioned inside an
editor. We'll start with a baseline Rails 7 application scaffolded by
`rails new`, making incremental improvements along the way.

First, our Action View templates will render "@"-prefixed usernames as
`<a>` elements. Next, our Active Record models will transform
"@"-mentions into [Action Text attachments][] prior to writing to the
database. Finally, we'll lean on Action Text to insert "@"-prefixed
attachments _directly_ into the content from within the browser.

Our client-side code will rely on built-in functionality provided by the
browser when possible. Whenever those capabilities aren't enough, we'll
utilize [Trix.js][] for rich text editing, [Turbo][] Frames for loading
content asynchronously, and [Stimulus][] Controllers to fill in any
other gaps.

The code samples contained below omit the majority of the application's
setup. The rest of the source code from this article can be found [on
GitHub][].

[on GitHub]: https://github.com/seanpdoyle/hotwire-example-template/commits/hotwire-example-action-text-mentions
[Action Text]: https://edgeguides.rubyonrails.org/action_text_overview.html
[Action Text attachments]: https://edgeguides.rubyonrails.org/action_text_overview.html#rendering-attachments

Our domain
---

The domain for the application involves two models: `Message` and
`User`.

Our application's initial model, controller, and view code was created
by Rails' `scaffold` generator:

```sh
bin/rails generate scaffold Message
bin/rails generate scaffold User \
  username:citext:index \
  name:citext
```

The only data that `Message` models retain directly are their `id`,
`created_at`, and `updated_at` columns. `Message` records serve as
entities for our application's `ActionText::RichText` records to
reference through a `has_rich_text :content` relationship declared
within the `Message` class.

In addition to their `id` column, `User` records are identified by their
unique `username` values, and also store a `name` value. Our `User` and
`Message` records don't have any direct relationships to one another.

The `messages/form` partial generated by the `bin/rails generate
scaffold Message` command will serve as our starting point. We'll be
spending most of our time and effort making changes to this template:

```erb
<%# app/views/messages/_form.html.erb %>

<%= form_with(model: message) do |form| %>
  <% if message.errors.any? %>
    <div id="error_explanation">
      <h2><%= pluralize(message.errors.count, "error") %> prohibited this message from being saved:</h2>
      <ul>
        <% message.errors.each do |error| %>
          <li><%= error.full_message %></li>
        <% end %>
      </ul>
     </div>
   <% end %>

   <div class="field">
     <%= form.label :content %>
     <%= form.rich_text_area :content %>
   </div>

   <div class="actions">
     <%= form.submit %>
   </div>
<% end %>
```

Render-time mentions
---

To demonstrate the concept of a mention, our initial implementation will
scan a `Message` record's `content.body` and replace all occurrences of
`@`-prefixed usernames with `<a>` elements. The `<a>` elements will link
to the `users#show` route and treat the `@`-prefixed handle as the
`/users/:id` route's `:id` dynamic segment.

To start, we'll perform a search-and-replace at render-time.

Action View has built-in support for searching a corpus of text and
replacing portions that match a regular expression via
[ActionView::Helpers::TextHelper#highlight][]. The search will be
powered by the [following regular expression][at-mention]:

```ruby
/\B\@(\w+)/
```

When a match occurs, replace the content with an `<a>` element generated
with the [link_to][] helper:

```diff
--- a/app/views/messages/_message.html.erb
+++ b/app/views/messages/_message.html.erb
   <p>
     <strong>Content:</strong>
-    <%= message.content %>
+    <%= highlight(message.content.body.to_html, /\B\@(\w+)/) { |handle| link_to handle, user_path(handle) } %>
   </p>
```

Since the mentions are entirely String-based, they won't include any
information related to a `User` record's identifier. We'll need to add
support for resolveing records based on the `params[:id]` path
parameter.

The generated `UsersController#set_user` helper method queries rows by
their `id` column, which we'll continue to support. In addition to
finding records by their `id`, we'll _also_ want to include records
whose `username` matches the `params[:id]` value without any preceding
`@` character:

```diff
--- a/app/controllers/users_controller.rb
+++ b/app/controllers/users_controller.rb
     def set_user
-      @user = User.find(params[:id])
+      users_with_id = User.where id: params[:id]
+      users_with_username_matching_handle = User.where username: params[:id].delete_prefix("@")
+
+      @user = users_with_id.or(users_with_username_matching_handle).first!
     end
```

Chaining [first!][] to the end of the query means that a query without
any results will raise an `ActiveRecord::RecordNotFound` the same way
that [ActiveRecord::FinderMethods#find][] would.

[ActionView::Helpers::TextHelper#highlight]: https://rubular.com/r/k84OJzvLG637yu
[at-mention]: https://rubular.com/r/TsYHIqAAsubDEy
[link_to]: https://edgeapi.rubyonrails.org/classes/ActionView/Helpers/UrlHelper.html#method-i-link_to
[first!]: https://edgeapi.rubyonrails.org/classes/ActiveRecord/FinderMethods.html#method-i-first-21
[ActiveRecord::FinderMethods#find]: https://edgeapi.rubyonrails.org/classes/ActiveRecord/FinderMethods.html#method-i-find

## Write-time mentions

So far, our implementation handles "@"-mentioning `User` records based
on their `username` values. However, by deferring our transformations
until render-time, we miss out on any database-level constraints or
guarantees that could prevent linking an "@"-mention to a `User` that
doesn't exist.

We can do better. Let's `User`-mentions one phase earlier in the
messaging process: at write-time.

We can continue to rely on the same regular expression to identify
`@`-prefixed mentions. Instead of using the `highlight` helper to inject
`<a>` elements into our templates, let's _attach_ the `User` records
directly to the rich text content.

In order to utilize our "@"-mention `User` query outside of the
`UsersController`, extract the `User.username_matching_handle` scope
into `app/models/user.rb`:

```diff
--- a/app/models/user.rb
+++ b/app/models/user.rb
 class User < ApplicationRecord
+  scope :username_matching_handle, ->(handle) { where username: handle.delete_prefix("@") }
 end

--- a/app/controllers/users_controller.rb
+++ b/app/controllers/users_controller.rb
     def set_user
       users_with_id = User.where id: params[:id]
-      users_with_username_matching_handle = User.where username: params[:id].delete_prefix("@")
+      users_with_username_matching_handle = User.username_matching_handle params[:id]

       @user = users_with_id.or(users_with_username_matching_handle).first!
     end
```

Next, we'll declare a [before_save][] callback to the `Message` model.
Prior to writing the record to the database, we'll scan the rich
content's HTML for "@"-prefixed words. If there is a `User` record whose
`username` matches the mention, we'll build a [ActionText::Attachment][]
instance and replace the mention with an HTML representation of that
attachment. If there are no corresponding `User` records, the mention
will remain unchanged:

```diff
--- a/app/models/message.rb
+++ b/app/models/message.rb
 class Message < ApplicationRecord
   has_rich_text :content
+
+  before_save do
+    content.body = content.body.to_html.gsub(/\B\@(\w+)/) do |handle|
+      if (user = User.username_matching_handle(handle).first)
+        ActionText::Attachment.from_attachable(user).to_html
+      else
+        handle
+      end
+    end
+  end
 end
 end
```

In order for the `ActionText::Attachment.from_attachable` call to
transform the `User` into Action Text-compliant HTML, we'll need to mix
the `ActionText::Attachment` module into the `User` class:

```diff
--- a/app/models/user.rb
+++ b/app/models/user.rb
@@ -1,2 +1,13 @@
 class User < ApplicationRecord
+  include ActionText::Attachable
+
   scope :username_matching_handle, ->(handle) { where username: handle.delete_prefix("@") }
 end
```

[before_save]: https://edgeguides.rubyonrails.org/active_record_callbacks.html#creating-an-object
[ActionText::Attachment]: https://edgeapi.rubyonrails.org/classes/ActionText/Attachment.html
[ActionText::Attachable]: https://edgeapi.rubyonrails.org/classes/ActionText/Attachable.html

Rendering attachments
---

Since mentions are processed by the model, we can remove the
`messages/message` partial's call to[highlight][], and restore the
original the `message.content` call:

```diff
--- a/app/views/messages/_message.html.erb
+++ b/app/views/messages/_message.html.erb
   <p>
     <strong>Content:</strong>
-    <%= highlight(message.content.body.to_html, /^@(.*?)$/) { |handle| link_to handle, user_path(handle) } %>
+    <%= message.content %>
   </p>
```

[highlight]: https://edgeapi.rubyonrails.org/classes/ActionView/Helpers/TextHelper.html#method-i-highlight

In it's place, we'll declare a `users/attachable` partial to serve as
the template Action Text will use to [transform a `User` attachment into
HTML][Rendering Attachments]:

```erb
<%# app/views/users/_attachable.html.erb %>

<%= link_to user_path(user) do %>
  @<%= user.username %>
<% end %>
```

Finally, we'll declare `User#to_attachable_partial_path` to reference
the `users/attachable` partial:

```diff
--- a/app/models/user.rb
+++ b/app/models/user.rb
 class User < ApplicationRecord
   include ActionText::Attachable

   scope :username_matching_handle, ->(handle) { where username: handle.delete_prefix("@") }
+
+  def to_attachable_partial_path
+    "users/attachable"
+  end
 end
```

[Rendering Attachments]: https://edgeguides.rubyonrails.org/action_text_overview.html#rendering-attachments

## Draft-time mentions

Our next improvement involves handling `User`-mentions one phase earlier
than a `Message` record's write-time: at draft-time.

Attaching `User` records to a message draft requires direct access to an
[Action Text][]-powered `<trix-editor>` element. Our current combination
of Rails and [Turbo][] doesn't afford our client-side with the tools to
achieve that level of control, so let's add [Stimulus][] to the mix!

We'll declare our first [Stimulus Controller][] to attach behavior to
our document's HTML elements.

```javascript
// app/javascript/controllers/mentions_controller.js

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
}
```

The controller will connect to elements that declare a `[data-controller]`
attribute that contains the `mentions` [identifier][].

Our controller will need direct access to the document's
[`<trix-editor>`][trix-editor] element. We'll add `editor` to the
controller's list of [target properties][]:

```diff
+++ a/app/javascript/controllers/mentions_controller.js
+++ b/app/javascript/controllers/mentions_controller.js
 import { Controller } from "@hotwired/stimulus"

 export default class extends Controller {
+  static get targets() { return [ "editor" ] }
 }
```

Once we've declared the controller module, we'll need to annotate the
HTML so that our controller can attach behavior to the elements. We'll
declare the `[data-controller="mentions"]` attribute on the
`/messages/new` page's `<form>` element, and make sure that our
`<trix-editor>` element declares the `[data-mentions-target="editor"]`
attribute:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
@@ -1,4 +1,4 @@
-<%= form_with(model: message) do |form| %>
+<%= form_with(model: message, data: { controller: "mentions" }) do |form| %>
   <% if message.errors.any? %>
     <div id="error_explanation">
       <h2><%= pluralize(message.errors.count, "error") %> prohibited this message from being saved:</h2>
@@ -13,10 +13,22 @@

   <div class="field">
     <%= form.label :content %>
-    <%= form.rich_text_area :content %>
+    <%= form.rich_text_area :content, data: { mentions_target: "editor" } %>
   </div>
```

We'll render a `<button type="button">` element for each `User` record:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
   <div class="actions">
     <%= form.submit %>
   </div>
+
+  <fieldset>
+    <legend>Mentions</legend>
+
+    <% User.all.order(username: :asc).each do |user| %>
+      <button type="button">
+        <%= user.name %>
+      </button>
+    <% end %>
+  </div>
 <% end %>
```

Next, we'll attach a mention when its corresponding `<button>` element
is clicked. To do so, we'll declare a `data-` attribute powered
[Stimulus Action][] comprised of `click` (which corresponds to the
built-in [click][] event), `mentions` (which corresponds to our
controller's [identifier][]), and `insert`, which corresponds to the
name of the method on the controller we'll invoke whenever a `click`
occurs:

```diff
--- a/app/views/mentions/new.html.erb
+++ b/app/views/mentions/new.html.erb
   <% User.all.order(username: :asc).each do |user| %>
-    <button type="button">
+    <button type="button"
+            data-action="click->mentions#insert">
       <%= user.name %>
     </button>
   <% end %>
```

Within the `mentions#insert` action, we'll need to create and insert a
[Trix.Attachment][], reading its `sgid` and `content` options directly
from the `<button type="button">` element that triggered the `click`
event:

```diff
--- a/app/assets/javascripts/controllers/mentions_controller.js
+++ b/app/assets/javascripts/controllers/mentions_controller.js
 import { Controller } from "@hotwired/stimulus"

 export default class extends Controller {
   static get targets() { return [ "editor" ] }
+
+  insert({ target: { value, innerHTML } }) {
+    const { editor } = this.editorTarget
+
+    editor.insertAttachment(new Trix.Attachment({ sgid: value, content: innerHTML }))
+  }
+}
```

We'll be directly encoding the [`sgid` and
`content`][attachment-properties] into the `<button>` element's [name][]
and [innerHTML][] properties:

```diff
--- a/app/views/mentions/new.html.erb
+++ b/app/views/mentions/new.html.erb
   <% User.all.order(username: :asc).each do |user| %>
-    <button type="button"
+    <button type="button" name="sgid" value="<%= user.attachable_sgid %>"
             data-action="click->mentions#insert">
       <%= user.name %>
     </button>
   <% end %>
```

While the `sgid` value is _always_ significant, the `content` is only
used for attachment-time rendering, and will be replaced with whatever
HTML the server resolves the resulting `<action-text-attachment>`
element to on subsequent viewings.

[Trix.Attachment]: https://github.com/basecamp/trix/tree/1.3.1#inserting-a-content-attachment
[attachment-properties]: https://edgeguides.rubyonrails.org/action_text_overview.html#rendering-attachments
[name]: https://developer.mozilla.org/en-US/docs/Web/HTML/Element/button#attr-name
[innerHTML]: https://developer.mozilla.org/en-US/docs/Web/API/Element/innerHTML

Re-use the trix content attachment HTML partial

```erb
<%# app/views/mentions/_mention.html.erb %>
<%= user.name %>
```

```diff
--- a/app/models/user.rb
+++ b/app/models/user.rb
   scope :username_matching_handle, ->(handle) { where username: handle.delete_prefix("@") }

+  def to_trix_content_attachment_partial_path
+    "mentions/mention"
+  end
+
   def to_attachable_partial_path
     "users/attachable"
   end
```

```diff
--- a/app/views/users/_attachable.html.erb
+++ b/app/views/users/_attachable.html.erb
 <%= link_to user_path(user) do %>
-  @<%= user.username %>
+  <%= render partial: user.to_trix_content_attachment_partial_path, locals: { user: user } %>
 <% end %>

--- a/app/views/mentions/new.html.erb
+++ b/app/views/mentions/new.html.erb
   <% User.all.order(username: :asc).each do |user| %>
     <button type="button" name="sgid" value="<%= user.attachable_sgid %>" data-action="click->mentions#insert">
-      <%= user.name %>
+      <%= render partial: user.to_trix_content_attachment_partial_path, locals: { user: user } %>
     </button>
   <% end %>
```

Now that we're relying on Action Text and Trix to manage attachments on
our behalf, it's no longer necessary to extract attachments during the
creation of the `Message` records themselves, so we let's remove the
`before_save` block:

```diff
--- a/app/models/message.rb
+++ b/app/models/message.rb
 class Message < ApplicationRecord
   has_rich_text :content
-
-  before_save do
-    content.body = content.body.to_html.gsub(/\B\@(\w+)/) do |handle|
-      if (user = User.username_matching_handle(handle).first)
-        ActionText::Attachment.from_attachable(user).to_html
-      else
-        handle
-      end
-    end
-  end
 end
```

[Action Text]: https://edgeguides.rubyonrails.org/action_text_overview.html#what-is-action-text-questionmark
[Turbo]: https://turbo.hotwire.dev
[Stimulus]: https://stimulus.hotwire.dev
[Stimulus Controller]: https://stimulus.hotwire.dev/handbook/hello-stimulus#it-all-starts-with-html
[identifier]: https://stimulus.hotwire.dev/reference/controllers#identifiers
[trix-editor]: https://github.com/basecamp/trix/tree/1.3.1#creating-an-editor
[target properties]: https://stimulus.hotwire.dev/handbook/building-something-real#defining-the-target
[Stimulus Action]: https://stimulus.hotwire.dev/handbook/building-something-real#connecting-the-action
[click]: https://developer.mozilla.org/en-US/docs/Web/API/Element/click_event

## Lazily-loaded mentions

As the `users` table grows, the cost of retrieving and rendering _every_
`User` record as a `<button>` that creates a mention  will grow with it.
We can defer that cost until _after_ the initial request by delaying the
retrieval of those records.

Let's extract our template's `User.all.order(username: :asc)` loop to
its own controller action and template, then fetch that HTML over HTTP
with a [Turbo Frame][].

Turbo declares a `<turbo-frame>` [custom element][] that enable
applications to decompose pages into separate segments that each have
load and navigation life cycles that operate independently from one
another.

[Turbo Frame]: https://turbo.hotwire.dev/handbook/frames#lazily-loading-frames
[custom element]: https://developer.mozilla.org/en-US/docs/Web/Web_Components/Using_custom_elements

First, we'll declare an index route to handle `GET /mentions` requests:

```diff
--- a/config/routes.rb
+++ b/config/routes.rb
@@ -1,4 +1,5 @@
 Rails.application.routes.draw do
+  resources :mentions, only: :index
   resources :messages
   resources :users
   # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
```

Next, we'll introduce the corresponding `MentionsController`, and
declare `@users` to retain a reference the results of the Active Record
query:

```ruby
class MentionsController < ApplicationController
  def index
    @users = User.all.order(username: :asc)
  end
end
```

Then, we'll remove the loop from the `messages/form` partial into the
new `mentions/index` template. In it's place, we'll declare a
`<turbo-frame>` element:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
   <fieldset>
     <legend>Mentions</legend>

-    <% User.all.order(username: :asc).each do |user| %>
-      <button type="button" name="sgid" value="<%= user.attachable_sgid %>"
-              data-action="click->mentions#insert">
-        <%= render partial: user.to_trix_content_attachment_partial_path, locals: { user: user } %>
-      </button>
-    <% end %>
+    <turbo-frame id="mentions" src="<%= mentions_path %>"></turbo-frame>
   </fieldset>
 <% end %>
```

Declaring the element with a `[src]` attribute and an empty set of
descendants directs the element to issue a `GET` request to the provided
path or URL to [load its content asynchronously][].

It's important that the HTML response from the `GET` request includes a
`<turbo-frame>` element with an `[id]` attribute that [matches the
`id`][] of the `<turbo-frame>` element that initiated the request. To
guarantee parity in response, the `mentions#index` templates renders a
`<turbo-frame id="mentions">` element:

```diff
--- /dev/null
+++ b/app/views/mentions/index.html.erb
+<turbo-frame id="mentions">
+</turbo-frame>
```

Finally, insert the `<fieldset>` element's original contents, looping
over the results of the controller's `@users` query:

```diff
--- a/app/views/mentions/index.html.erb
+++ b/app/views/mentions/index.html.erb
 <turbo-frame id="mentions">
+  <% @users.each do |user| %>
+    <button type="button" name="sgid" value="<%= user.attachable_sgid %>"
+            data-action="click->mentions#insert">
+      <%= render partial: user.to_trix_content_attachment_partial_path, locals: { user: user } %>
+    </button>
+  <% end %>
 </turbo-frame>
```

[load its content asynchronously]: https://turbo.hotwire.dev/handbook/frames#lazily-loading-frames
[matches the `id`]: https://turbo.hotwire.dev/handbook/introduction#turbo-frames%3A-decompose-complex-pages

## Filtered-out mentions

Now that we're fetching our list of `User` records asynchronously
on-demand, we have an opportunity to provide end-users with control over
how the results are filtered.

By declaring a `[src]` value, we're controlling which URL our
`<turbo-frame>` element initially navigates. Pairing the
`<turbo-frame>` element with a corresponding `<form>` element, we can
share that control with our end-users.

First', we'll remove the `[src]` attribute from our `<turbo-frame>`
element, making it inert upon page-load:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
@@ -23,6 +23,13 @@
   <fieldset>
     <legend>Mentions</legend>

-    <turbo-frame id="mentions" src="<%= mentions_path %>"></turbo-frame>
+    <turbo-frame id="mentions"></turbo-frame>
   </fieldset>
```

Next, we'll [add a `<form>` element to drive our `<turbo-frame>`][].
We'll declare the `<form>` with `[data-turbo-frame]` attribute that
matches the `<turbo-frame>` element's `[id]` value, and an `[action]`
attribute with a value that matches the `<turbo-frame>` element's
original `[src]` value:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
 <% end %>
+
+<form action="<%= mentions_path %>" data-turbo-frame="mentions">
+</form>
```

Next, we'll declare a `<label>` and `<input>` pairing within the
`<form>` element so that end-users can enter a query term for filtering
the `User` records:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
 <form action="<%= mentions_path %>" data-turbo-frame="mentions">
+  <label for="new_mention_username">Username</label>
+  <input id="new_mention_username" name="username" type="search" autocomplete="username" autocorrect="off">
+
+  <button>Search</button>
 </form>
```

Since we'll be filtering `User` records based on their `username` value,
we'll declare the `<input type="search">` element with
[autocomplete="username"][] and [autocorrect="off"][] values.

[add a `<form>` element to drive our `<turbo-frame>`]: https://turbo.hotwire.dev/handbook/frames#targeting-navigation-into-or-out-of-a-frame
[autocomplete="username"]: https://developer.mozilla.org/en-US/docs/Web/HTML/Attributes/autocomplete#values
[autocorrect="off"]: https://developer.mozilla.org/en-US/docs/Web/HTML/Element/Input#autocorrect

Finally, we'll change our `mentions#index` controller action to provide
the Active Record query with the filter value from the request URL's
`?username` query parameter:

```diff
--- a/app/controllers/mentions_controller.rb
+++ b/app/controllers/mentions_controller.rb
 class MentionsController < ApplicationController
   def index
-    @users = User.order(username: :asc)
+    @users = User.order(username: :asc).username_matching_handle params[:username]
   end
 end
```

For simplicity's sake, we'll change our `User.mentioned` scope to rely
on SQL's [ILIKE][]-powered pattern matching:

```diff
--- a/app/models/user.rb
+++ b/app/models/user.rb
 class User < ApplicationRecord
   include ActionText::Attachable

-  scope :username_matching_handle, ->(handle) { where username: handle.delete_prefix("@") }
+  scope :username_matching_handle, ->(handle) { where <<~SQL, handle.delete_prefix("@") + "%" }
+    username ILIKE ?
+  SQL

   def to_trix_content_attachment_partial_path
```

Once implemented, the experience could be improved by more powerful
search tools (e.g. PostgresSQL's [full-text searching][] capabilities):

[ILIKE]: https://www.postgresql.org/docs/12/functions-matching.html#FUNCTIONS-LIKE
[full-text searching]: https://www.postgresql.org/docs/12/textsearch.html

## Filtered-out mentions

Now that we're fetching our list of `User` records asynchronously
on-demand, we have an opportunity to provide end-users with control over
how the results are filtered.

By declaring a `[src]` value, we're controlling which URL our
`<turbo-frame>` element initially navigates. Pairing the
`<turbo-frame>` element with a corresponding `<form>` element, we can
share that control with our end-users.

First', we'll remove the `[src]` attribute from our `<turbo-frame>`
element, making it inert upon page-load:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
@@ -23,6 +23,13 @@
   <fieldset>
     <legend>Mentions</legend>

-    <turbo-frame id="mentions" src="<%= mentions_path %>"></turbo-frame>
+    <turbo-frame id="mentions"></turbo-frame>
   </fieldset>
```

Next, we'll [add a `<form>` element to drive our `<turbo-frame>`][].
We'll declare the `<form>` with `[data-turbo-frame]` attribute that
matches the `<turbo-frame>` element's `[id]` value, and an `[action]`
attribute with a value that matches the `<turbo-frame>` element's
original `[src]` value:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
 <% end %>
+
+<form action="<%= mentions_path %>" data-turbo-frame="mentions">
+</form>
```

Next, we'll declare a `<label>` and `<input>` pairing within the
`<form>` element so that end-users can enter a query term for filtering
the `User` records:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
 <form action="<%= mentions_path %>" data-turbo-frame="mentions">
+  <label for="new_mention_username">Username</label>
+  <input id="new_mention_username" name="username" type="search" autocomplete="username" autocorrect="off">
+
+  <button>Search</button>
 </form>
```

Since we'll be filtering `User` records based on their `username` value,
we'll declare the `<input type="search">` element with
[autocomplete="username"][] and [autocorrect="off"][] values.

[add a `<form>` element to drive our `<turbo-frame>`]: https://turbo.hotwire.dev/handbook/frames#targeting-navigation-into-or-out-of-a-frame
[autocomplete="username"]: https://developer.mozilla.org/en-US/docs/Web/HTML/Attributes/autocomplete#values
[autocorrect="off"]: https://developer.mozilla.org/en-US/docs/Web/HTML/Element/Input#autocorrect

Finally, we'll change our `mentions#index` controller action to provide
the Active Record query with the filter value from the request URL's
`?username` query parameter:

```diff
--- a/app/controllers/mentions_controller.rb
+++ b/app/controllers/mentions_controller.rb
 class MentionsController < ApplicationController
   def index
-    @users = User.order(username: :asc)
+    @users = User.order(username: :asc).username_matching_handle params[:username]
   end
 end
```

For simplicity's sake, we'll change our `User.mentioned` scope to rely
on SQL's [ILIKE][]-powered pattern matching:

```diff
--- a/app/models/user.rb
+++ b/app/models/user.rb
 class User < ApplicationRecord
   include ActionText::Attachable

-  scope :username_matching_handle, ->(handle) { where username: handle.delete_prefix("@") }
+  scope :username_matching_handle, ->(handle) { where <<~SQL, handle.delete_prefix("@") + "%" }
+    username ILIKE ?
+  SQL

   def to_trix_content_attachment_partial_path
```

Once implemented, the experience could be improved by more powerful
search tools (e.g. PostgresSQL's [full-text searching][] capabilities):

[ILIKE]: https://www.postgresql.org/docs/12/functions-matching.html#FUNCTIONS-LIKE
[full-text searching]: https://www.postgresql.org/docs/12/textsearch.html

## Keyboard-navigate mentions

import github/combobox-nav via Skypack

[role="combobox"]: https://www.w3.org/TR/wai-aria-1.1/#combobox
[role="listbox"]: https://www.w3.org/TR/wai-aria-1.1/#listbox
[Combobox interactions]: https://www.w3.org/TR/wai-aria-practices-1.1/#combobox
[Combobox attributes]: https://www.w3.org/TR/wai-aria-practices-1.1/#wai-aria-roles-states-and-properties-6
[Combobox keyboard interactions]: https://www.w3.org/TR/wai-aria-practices-1.1/#keyboard-interaction-6

```diff
--- a/app/javascript/controllers/mentions_controller.js
+++ b/app/javascript/controllers/mentions_controller.js
 import { Controller } from "@hotwired/stimulus"
+import Combobox from "https://cdn.skypack.dev/@github/combobox-nav"

 export default class extends Controller {
```

ensure that the `listboxTarget` has `[role="listbox"]`, and that the
`editorTarget` toggles between `[role="textbox"]` when inactive and
`[role="combobox"]` when active.

```diff
--- a/app/javascript/controllers/mentions_controller.js
+++ b/app/javascript/controllers/mentions_controller.js
   toggle(expanded) {
     if (expanded) {
       this.listboxTarget.hidden = false
+      this.listboxTarget.setAttribute("role", "listbox")
+      this.editorTarget.setAttribute("role", "combobox")
       this.editorTarget.setAttribute("autocomplete", "username")
       this.editorTarget.setAttribute("autocorrect", "off")
     } else {
       this.listboxTarget.hidden = true
+      this.listboxTarget.removeAttribute("role")
+      this.editorTarget.setAttribute("role", "textbox")
       this.editorTarget.removeAttribute("autocomplete")
       this.editorTarget.removeAttribute("autocorrect")
     }
   }
```

ensure that all options have unique `[id]` and `[role="option"]`

```diff
--- a/app/views/mentions/new.html.erb
+++ b/app/views/mentions/new.html.erb
 <turbo-frame id="mentions">
   <% @users.each do |user| %>
-    <button type="button" name="sgid" value="<%= user.attachable_sgid %>"
+    <button type="button" name="sgid" value="<%= user.attachable_sgid %>" id="<%= dom_id user, :mention %>" role="option"
             data-action="click->mentions#insert">
       <%= render partial: user.to_trix_content_attachment_partial_path, object: user, as: :user %>
     </button>
   <% end %>
```

clear any previous state, then wire up a `Combobox` instance when the
mentions are expanded, teardown otherwise

```diff
--- a/app/javascript/controllers/mentions_controller.js
+++ b/app/javascript/controllers/mentions_controller.js
   toggle(expanded) {
     if (expanded) {
       this.listboxTarget.hidden = false
       this.listboxTarget.setAttribute("role", "listbox")
       this.editorTarget.setAttribute("autocomplete", "username")
       this.editorTarget.setAttribute("autocorrect", "off")
       this.editorTarget.setAttribute("role", "combobox")
+
+      this.combobox?.destroy()
+      this.combobox = new Combobox(this.editorTarget, this.listboxTarget)
+      this.combobox.start()
     } else {
       this.listboxTarget.hidden = true
       this.listboxTarget.removeAttribute("role")
       this.editorTarget.removeAttribute("autocomplete")
       this.editorTarget.removeAttribute("autocorrect")
       this.editorTarget.setAttribute("role", "textbox")
+
+      this.combobox?.destroy()
     }
   }
```

Collapse when `<trix-editor>` element loses focus, when the
`<trix-editor>` element's cursor moves outside the `@`-prefixed "word",
or on <kbd>escape</kbd>:

```diff
--- a/app/views/messages/_form.html.erb
+++ b/app/views/messages/_form.html.erb
@@ -14,7 +14,12 @@

   <div class="field">
     <%= form.label :content %>
-    <%= form.rich_text_area :content, data: { mentions_target: "editor" } %>
+    <%= form.rich_text_area :content, data: { mentions_target: "editor",
+                                              action: "
+                                                keydown->mentions#collapseOnEscape
+                                                keydown->mentions#collapseOnCursorExit
+                                                trix-blur->mentions#collapse
+                                               " } %>

     <button form="new_mention" name="username" data-mentions-target="submit" hidden>Search</button>
   </div>
```

implement the actions

```javascript
// app/javascript/controllers/mentions_controller.js

collapseOnEscape({ key }) {
  if (key == "Escape") this.collapse()
}

collapseOnCursorExit({ target: { editor } }) {
  const mention = findMentionFromCursor(editor, this.wordPatternValue, this.breakPatternValue)

  if (mention) return
  else this.toggle(false)
}

collapse() {
  if (this.editorTarget.hasAttribute("aria-activedescendant")) return
  else this.toggle(false)
}
```

reset state and teardown the `Combobox` instance when disconnected from the page

```diff
--- a/app/javascript/controllers/mentions_controller.js
+++ b/app/javascript/controllers/mentions_controller.js
 import { Controller } from "@hotwired/stimulus"
 import Combobox from "https://cdn.skypack.dev/@github/combobox-nav"

 export default class extends Controller {
   static get targets() { return [ "editor", "listbox", "submit" ] }
   static get values() { return { wordPattern: String, breakPattern: String } }
+
+  disconnect() {
+    this.toggle(false)
+  }
```

minimal visual styles to indicate `[aria-selected]` movement

```diff
--- a/app/assets/stylesheets/application.css
+++ b/app/assets/stylesheets/application.css
  *= require_tree .
  *= require_self
  */
+
+[aria-selected="true"]  { outline: 2px dotted black; }
```
