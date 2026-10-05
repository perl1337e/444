<script lang="ts">
  import '../app.css';
  import { onMount } from 'svelte';
  import { initSettings } from '$lib/settings';

  onMount(initSettings);
</script>

<slot />
